import Foundation
import ImageIO
@testable import Cairn
import Testing
import UIKit
import UniformTypeIdentifiers

@Suite("InlineImageCache Tests")
struct InlineImageCacheTests {
  // MARK: - Safety gate

  @Test
  func `Probe returns nil for a private-IP host`() async throws {
    let url = try #require(URL(string: "http://127.0.0.1/test.png"))
    let result = await InlineImageCache.shared.probeImageDimensions(url: url)
    #expect(result == nil)
  }

  @Test
  func `Probe returns nil for a non-HTTP scheme`() async throws {
    let url = try #require(URL(string: "ftp://example.com/test.png"))
    let result = await InlineImageCache.shared.probeImageDimensions(url: url)
    #expect(result == nil)
  }

  // MARK: - HTML reroute

  @Test
  func `An image URL that serves HTML returns notImage and stays retryable`() async {
    let cache = InlineImageCache(session: Self.stubbedSession())
    let url = Self.htmlServingURL()

    let first = await cache.fetchImageData(for: url)
    #expect(Self.isNotImage(first))

    // A reroute must not poison the negative cache: re-fetching runs the
    // network path again rather than short-circuiting to .failed, so a chat
    // re-entry can still discover the page and load its og:image.
    let second = await cache.fetchImageData(for: url)
    #expect(Self.isNotImage(second))
  }

  @Test
  func `An oversized HTML page still returns notImage instead of tripping the size guard`() async {
    let cache = InlineImageCache(session: Self.stubbedSession())
    let url = Self.htmlServingURL(oversized: true)

    // The mime-type check must precede the download-size guard, so a page
    // larger than the image cap reroutes rather than dead-ending as .failed.
    let result = await cache.fetchImageData(for: url)
    #expect(Self.isNotImage(result))
  }

  // MARK: - Download bound

  @Test
  func `An image within the download cap loads`() async throws {
    let cache = InlineImageCache(session: Self.stubbedSession(ImageResponseURLProtocol.self))
    let url = Self.imageServingURL(.valid)

    let result = await cache.fetchImageData(for: url)

    guard case let .loaded(data) = result else {
      Issue.record("Expected the image to load, got \(result)")
      return
    }
    #expect(data == ImageResponseURLProtocol.validImage)
  }

  @Test
  func `A body that runs past the download cap fails without a declared length`() async {
    let cache = InlineImageCache(session: Self.stubbedSession(ImageResponseURLProtocol.self))
    let url = Self.imageServingURL(.oversizedBody)

    // No Content-Length to reject on, so the cap has to hold mid-stream.
    let result = await cache.fetchImageData(for: url)
    #expect(Self.isFailed(result))
  }

  @Test
  func `A declared length over the download cap is rejected`() async {
    let cache = InlineImageCache(session: Self.stubbedSession(ImageResponseURLProtocol.self))
    let url = Self.imageServingURL(.oversizedLength)

    let result = await cache.fetchImageData(for: url)
    #expect(Self.isFailed(result))
  }

  @Test
  func `A probe body over the probe cap returns no dimensions`() async {
    let cache = InlineImageCache(session: Self.stubbedSession(ImageResponseURLProtocol.self))
    let url = Self.imageServingURL(.oversizedBody)

    #expect(await cache.probeImageDimensions(url: url) == nil)
  }

  @Test
  func `The default session is not the shared cookie-bearing session`() {
    let session = InlineImageCache.defaultSession
    #expect(session !== URLSession.shared)
    #expect(session.delegate is RedirectSafetyDelegate)
    #expect(session.configuration.httpCookieStorage !== HTTPCookieStorage.shared)
  }

  // MARK: - Decoded cache

  @Test
  func `Decoded cache returns nil for an unseen URL`() {
    let url = uniqueURL()
    #expect(InlineImageCache.shared.decoded(for: url) == nil)
  }

  @Test
  @MainActor
  func `Decoded cache round-trips a stored entry with raw bytes`() {
    let url = uniqueURL()
    let image = Self.makeImage()
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
    let entry = CachedDecodedImage(image: image, isGIF: false, data: bytes)
    InlineImageCache.shared.storeDecoded(entry, for: url)

    let result = InlineImageCache.shared.decoded(for: url)
    #expect(result?.image === image)
    #expect(result?.isGIF == false)
    #expect(result?.data == bytes)
  }

  @Test
  @MainActor
  func `Decoded cache preserves the GIF flag and omits bytes`() {
    let url = uniqueURL()
    let image = Self.makeImage()
    let entry = CachedDecodedImage(image: image, isGIF: true, data: nil)
    InlineImageCache.shared.storeDecoded(entry, for: url)

    let result = InlineImageCache.shared.decoded(for: url)
    #expect(result?.isGIF == true)
    #expect(result?.data == nil)
  }

  @Test
  @MainActor
  func `Re-storing the same key replaces the entry without growing the cache`() {
    let url = uniqueURL()
    let first = CachedDecodedImage(image: Self.makeImage(), isGIF: false, data: Data([0x01]))
    let second = CachedDecodedImage(image: Self.makeImage(), isGIF: true, data: nil)

    InlineImageCache.shared.storeDecoded(first, for: url)
    InlineImageCache.shared.storeDecoded(second, for: url)

    let result = InlineImageCache.shared.decoded(for: url)
    #expect(result?.image === second.image)
    #expect(result?.isGIF == true)
    #expect(result?.data == nil)
  }

  @Test
  @MainActor
  func `Decoded cost reflects pixel size plus raw bytes`() {
    let image = Self.makeImage(width: 100, height: 50)
    let bytes = Data(repeating: 0, count: 1000)
    let entry = CachedDecodedImage(image: image, isGIF: false, data: bytes)
    // 100x50 RGBA bitmap is 100 * 50 * 4 = 20_000 bytes minimum, plus
    // 1_000 raw bytes. CGImage.bytesPerRow may be padded for alignment,
    // so we assert a sane lower bound rather than an exact value.
    #expect(entry.cost >= 21000)
  }

  // MARK: - Helpers

  private func uniqueURL() -> URL {
    URL(string: "https://example.invalid/\(UUID().uuidString).png")!
  }

  /// An image-extension URL on an allow-listed CDN host, so the fetch's SSRF
  /// gate passes without a real DNS lookup and the stubbed session answers.
  private static func htmlServingURL(oversized: Bool = false) -> URL {
    let marker = oversized ? "-\(HTMLResponseURLProtocol.oversizedMarker)" : ""
    return URL(string: "https://media.giphy.com/\(UUID().uuidString)\(marker).jpg")!
  }

  /// An image-extension URL on an allow-listed CDN host whose stubbed
  /// response is picked by the marker in its path.
  private static func imageServingURL(_ response: ImageResponseURLProtocol.Response) -> URL {
    URL(string: "https://media.giphy.com/\(UUID().uuidString)-\(response.rawValue).png")!
  }

  private static func stubbedSession(
    _ protocolClass: URLProtocol.Type = HTMLResponseURLProtocol.self
  ) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [protocolClass]
    return URLSession(configuration: config)
  }

  private static func isNotImage(_ result: InlineImageResult) -> Bool {
    if case .notImage = result { return true }
    return false
  }

  private static func isFailed(_ result: InlineImageResult) -> Bool {
    if case .failed = result { return true }
    return false
  }

  @MainActor
  private static func makeImage(width: Int = 1, height: Int = 1) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
    return renderer.image { ctx in
      UIColor.black.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
  }
}

/// Answers any request with a 200 `text/html` response, standing in for an
/// image-extension URL that actually serves a landing page. A URL carrying
/// `oversizedMarker` returns a body larger than the fetch's 10MB image cap,
/// exercising that the HTML reclassification precedes the size guard.
private final class HTMLResponseURLProtocol: URLProtocol {
  static let oversizedMarker = "oversized"

  private static let htmlBody = Data("<html><body>landing page</body></html>".utf8)
  private static let oversizedByteCount = 11 * 1024 * 1024

  // swiftlint:disable:next static_over_final_class
  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  // swiftlint:disable:next static_over_final_class
  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url,
          let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
          ) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let body = url.absoluteString.contains(Self.oversizedMarker)
      ? Data(count: Self.oversizedByteCount)
      : Self.htmlBody
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Answers any request with a 200 `image/png` response whose body is picked by
/// the `Response` marker in the URL: a small valid image, or one of two ways
/// of exceeding the fetch's 10MB cap.
private final class ImageResponseURLProtocol: URLProtocol {
  enum Response: String, CaseIterable {
    case valid
    /// Over-cap body with no `Content-Length`, so only the stream reveals it.
    case oversizedBody
    /// Over-cap `Content-Length` in front of a small body.
    case oversizedLength
  }

  static let validImage = makePNG()
  private static let oversizedByteCount = 11 * 1024 * 1024
  private static let chunkByteCount = 1024 * 1024

  // swiftlint:disable:next static_over_final_class
  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  // swiftlint:disable:next static_over_final_class
  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url,
          let kind = Response.allCases.first(where: { url.absoluteString.contains("-\($0.rawValue).") }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    var headers = ["Content-Type": "image/png"]
    if kind == .oversizedLength {
      headers["Content-Length"] = String(Self.oversizedByteCount)
    }
    guard let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    ) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

    switch kind {
    case .valid, .oversizedLength:
      client?.urlProtocol(self, didLoad: Self.validImage)
    case .oversizedBody:
      for _ in 0..<(Self.oversizedByteCount / Self.chunkByteCount) {
        client?.urlProtocol(self, didLoad: Data(count: Self.chunkByteCount))
      }
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func makePNG() -> Data {
    let data = NSMutableData()
    guard let context = CGContext(
      data: nil,
      width: 4,
      height: 4,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ),
      let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
      return Data()
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
  }
}
