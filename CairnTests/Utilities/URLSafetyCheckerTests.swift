import Foundation
@testable import Cairn
import Testing

struct URLSafetyCheckerTests {
  // MARK: - Scheme Validation

  @Test
  func `Allows HTTPS URLs`() async throws {
    let url = try #require(URL(string: "https://example.com/page"))
    let result = await URLSafetyChecker.isSafe(url)
    #expect(result, "HTTPS should be allowed")
  }

  @Test
  func `Allows HTTP URLs`() async throws {
    let url = try #require(URL(string: "http://example.com/page"))
    let result = await URLSafetyChecker.isSafe(url)
    #expect(result, "HTTP should be allowed")
  }

  @Test
  func `Rejects FTP scheme`() async throws {
    let url = try #require(URL(string: "ftp://example.com/file"))
    let result = await URLSafetyChecker.isSafe(url)
    #expect(!result, "FTP should be rejected")
  }

  @Test
  func `Rejects file scheme`() async throws {
    let url = try #require(URL(string: "file:///etc/passwd"))
    let result = await URLSafetyChecker.isSafe(url)
    #expect(!result, "file:// should be rejected")
  }

  @Test
  func `Rejects javascript scheme`() async throws {
    let url = try #require(URL(string: "javascript:alert(1)"))
    let result = await URLSafetyChecker.isSafe(url)
    #expect(!result, "javascript: should be rejected")
  }

  // MARK: - Host Validation

  @Test
  func `Rejects URL with no host`() async throws {
    let url = try #require(URL(string: "https://"))
    let result = await URLSafetyChecker.isSafe(url)
    #expect(!result, "URL with no host should be rejected")
  }

  // MARK: - Allow-listed Hosts

  @Test
  func `Allows media.giphy.com`() async throws {
    let url = try #require(URL(string: "https://media.giphy.com/media/abc123/giphy.gif"))
    let result = await URLSafetyChecker.isSafe(url)
    #expect(result, "media.giphy.com should be allow-listed")
  }

  @Test
  func `Allows i.giphy.com`() async throws {
    let url = try #require(URL(string: "https://i.giphy.com/media/abc123/giphy.gif"))
    let result = await URLSafetyChecker.isSafe(url)
    #expect(result, "i.giphy.com should be allow-listed")
  }

  // MARK: - Private/Reserved IP Detection (IPv4)

  @Test
  func `Detects loopback 127.0.0.1`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("127.0.0.1"))
  }

  @Test
  func `Detects loopback 127.255.255.255`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("127.255.255.255"))
  }

  @Test
  func `Detects 10.0.0.0/8`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("10.0.0.1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("10.255.255.255"))
  }

  @Test
  func `Detects 172.16.0.0/12`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("172.16.0.1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("172.31.255.255"))
    #expect(!URLSafetyChecker.isPrivateOrReserved("172.32.0.1"), "172.32.x.x is public")
  }

  @Test
  func `Detects 192.168.0.0/16`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("192.168.0.1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("192.168.255.255"))
  }

  @Test
  func `Detects link-local 169.254.0.0/16`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("169.254.1.1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("169.254.169.254"), "AWS metadata endpoint")
  }

  @Test
  func `Detects 0.0.0.0`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("0.0.0.0"))
  }

  @Test
  func `Detects multicast 224.0.0.0/4`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("224.0.0.1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("239.255.255.255"))
  }

  @Test
  func `Detects reserved 240.0.0.0/4`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("240.0.0.1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("255.255.255.254"))
  }

  @Test
  func `Allows public IPv4 addresses`() {
    #expect(!URLSafetyChecker.isPrivateOrReserved("8.8.8.8"), "Google DNS is public")
    #expect(!URLSafetyChecker.isPrivateOrReserved("1.1.1.1"), "Cloudflare DNS is public")
    #expect(!URLSafetyChecker.isPrivateOrReserved("93.184.216.34"), "example.com is public")
  }

  // MARK: - Private/Reserved IP Detection (IPv6)

  @Test
  func `Detects IPv6 loopback ::1`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("::1"))
  }

  @Test
  func `Detects IPv6 unspecified ::`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("::"))
  }

  @Test
  func `Detects IPv6 link-local fe80::`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("fe80::1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("fe80::abcd:ef01:2345:6789"))
  }

  @Test
  func `Detects IPv6 unique local fc00::/7`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("fc00::1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("fd00::1"))
  }

  @Test
  func `Detects IPv4-mapped IPv6 addresses`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("::ffff:127.0.0.1"), "Mapped loopback")
    #expect(URLSafetyChecker.isPrivateOrReserved("::ffff:192.168.1.1"), "Mapped private")
    #expect(URLSafetyChecker.isPrivateOrReserved("::ffff:10.0.0.1"), "Mapped 10.x private")
    #expect(!URLSafetyChecker.isPrivateOrReserved("::ffff:8.8.8.8"), "Mapped public should pass")
  }

  @Test
  func `Detects IPv6 multicast ff00::/8`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("ff02::1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("ff05::2"))
  }

  @Test
  func `Allows public IPv6 addresses`() {
    #expect(!URLSafetyChecker.isPrivateOrReserved("2001:4860:4860::8888"), "Google DNS v6")
    #expect(!URLSafetyChecker.isPrivateOrReserved("2606:4700:4700::1111"), "Cloudflare v6")
  }

  // MARK: - Special-Purpose Ranges

  @Test
  func `Detects all of 0.0.0.0/8`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("0.0.0.1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("0.255.255.255"))
    #expect(!URLSafetyChecker.isPrivateOrReserved("1.0.0.0"))
  }

  @Test
  func `Detects carrier-grade NAT 100.64.0.0/10`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("100.64.0.1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("100.127.255.255"))
    #expect(!URLSafetyChecker.isPrivateOrReserved("100.63.255.255"))
    #expect(!URLSafetyChecker.isPrivateOrReserved("100.128.0.0"))
  }

  @Test
  func `Detects benchmarking 198.18.0.0/15`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("198.18.0.1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("198.19.255.255"))
    #expect(!URLSafetyChecker.isPrivateOrReserved("198.17.255.255"))
    #expect(!URLSafetyChecker.isPrivateOrReserved("198.20.0.0"))
  }

  @Test
  func `Detects IETF protocol assignments 192.0.0.0/24`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("192.0.0.1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("192.0.0.255"))
    #expect(!URLSafetyChecker.isPrivateOrReserved("192.0.1.1"))
  }

  @Test
  func `Detects IPv6 site-local fec0::/10`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("fec0::1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("feff::1"))
  }

  @Test
  func `Checks the IPv4 address embedded in NAT64 64:ff9b::/96`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("64:ff9b::127.0.0.1"))
    #expect(URLSafetyChecker.isPrivateOrReserved("64:ff9b::a9fe:a9fe"), "Metadata endpoint via NAT64")
    #expect(!URLSafetyChecker.isPrivateOrReserved("64:ff9b::8.8.8.8"))
  }

  @Test
  func `Checks the IPv4 address embedded in 6to4 2002::/16`() {
    #expect(URLSafetyChecker.isPrivateOrReserved("2002:c0a8:0101::1"), "Embeds 192.168.1.1")
    #expect(URLSafetyChecker.isPrivateOrReserved("2002:7f00:0001::"), "Embeds 127.0.0.1")
    #expect(!URLSafetyChecker.isPrivateOrReserved("2002:0808:0808::1"), "Embeds 8.8.8.8")
  }

  // MARK: - Connected Peer Addresses

  @Test
  func `Peer addresses in private ranges fail the connection check`() {
    #expect(!RemoteAddressSafetyDelegate.reachedOnlyPublicAddresses([
      (remoteAddress: "93.184.216.34", isProxyConnection: false),
      (remoteAddress: "10.0.0.5", isProxyConnection: false)
    ]))
    #expect(!RemoteAddressSafetyDelegate.reachedOnlyPublicAddresses([
      (remoteAddress: "fe80::1%en0", isProxyConnection: false)
    ]), "A zone suffix must not hide a link-local peer")
    #expect(!RemoteAddressSafetyDelegate.reachedOnlyPublicAddresses([
      (remoteAddress: "not-an-address", isProxyConnection: false)
    ]))
  }

  @Test
  func `Public, proxied, and addressless peers pass the connection check`() {
    #expect(RemoteAddressSafetyDelegate.reachedOnlyPublicAddresses([
      (remoteAddress: "93.184.216.34", isProxyConnection: false),
      (remoteAddress: "2606:4700:4700::1111", isProxyConnection: false),
      (remoteAddress: "10.0.0.1", isProxyConnection: true),
      (remoteAddress: nil, isProxyConnection: false)
    ]))
    #expect(RemoteAddressSafetyDelegate.reachedOnlyPublicAddresses([]))
  }

  // MARK: - Non-IP Hostnames

  @Test
  func `Non-IP strings are not private`() {
    #expect(!URLSafetyChecker.isPrivateOrReserved("example.com"))
    #expect(!URLSafetyChecker.isPrivateOrReserved("localhost"))
  }

  // MARK: - Lookup Timeout

  @Test
  func `A lookup that finishes in time returns its result`() async {
    let publicResult = await URLSafetyChecker.firstResult(within: .seconds(5), of: { true })
    let privateResult = await URLSafetyChecker.firstResult(within: .seconds(5), of: { false })
    #expect(publicResult == true)
    #expect(privateResult == false)
  }

  @Test
  func `A blocked lookup stops being awaited at the timeout`() async {
    let blockedFor: TimeInterval = 3
    let clock = ContinuousClock()
    let start = clock.now

    let result = await URLSafetyChecker.firstResult(within: .milliseconds(100)) {
      Thread.sleep(forTimeInterval: blockedFor)
      return true
    }

    // The late `true` must not win: a timeout fails closed.
    #expect(result == nil)
    #expect(clock.now - start < .seconds(blockedFor) / 2)
  }

  @Test
  func `Cancelling the caller stops the wait on a blocked lookup`() async {
    let blockedFor: TimeInterval = 3
    let clock = ContinuousClock()
    let start = clock.now

    let waiting = Task {
      await URLSafetyChecker.firstResult(within: .seconds(30)) {
        Thread.sleep(forTimeInterval: blockedFor)
        return true
      }
    }
    try? await Task.sleep(for: .milliseconds(50))
    waiting.cancel()

    #expect(await waiting.value == nil)
    #expect(clock.now - start < .seconds(blockedFor) / 2)
  }

  // MARK: - IP Literal URLs

  @Test
  func `Rejects URL with private IP literal`() async throws {
    let url = try #require(URL(string: "http://192.168.1.1/admin"))
    let result = await URLSafetyChecker.isSafe(url)
    #expect(!result, "Private IP URL should be rejected")
  }

  @Test
  func `Rejects URL with loopback IP literal`() async throws {
    let url = try #require(URL(string: "http://127.0.0.1:8080/api"))
    let result = await URLSafetyChecker.isSafe(url)
    #expect(!result, "Loopback IP URL should be rejected")
  }

  @Test
  func `Rejects metadata endpoint`() async throws {
    let url = try #require(URL(string: "http://169.254.169.254/latest/meta-data/"))
    let result = await URLSafetyChecker.isSafe(url)
    #expect(!result, "AWS metadata endpoint should be rejected")
  }

  @Test
  func `Rejects private IP with port`() async throws {
    let url = try #require(URL(string: "http://10.0.0.1:3000/api"))
    let result = await URLSafetyChecker.isSafe(url)
    #expect(!result, "Private IP with port should be rejected")
  }
}
