import Foundation
import ImageIO
@testable import Cairn
@testable import CairnServices
import Testing
import UIKit
import UniformTypeIdentifiers

struct ImageURLDetectorTests {
  // MARK: - Direct Image URL Detection

  @Test(arguments: ["jpg", "jpeg", "png", "gif", "webp", "heic"])
  func `Detects common image extensions`(ext: String) throws {
    let url = try #require(URL(string: "https://example.com/photo.\(ext)"))
    #expect(ImageURLClassifier.isDirectImageURL(url), "Should detect .\(ext)")
  }

  @Test(arguments: ["html", "pdf", "mp4", "txt", "js", "css"])
  func `Rejects non-image extensions`(ext: String) throws {
    let url = try #require(URL(string: "https://example.com/file.\(ext)"))
    #expect(!ImageURLClassifier.isDirectImageURL(url), "Should reject .\(ext)")
  }

  @Test
  func `Case insensitive extension detection`() throws {
    let url = try #require(URL(string: "https://example.com/photo.JPG"))
    #expect(ImageURLClassifier.isDirectImageURL(url))

    let urlMixed = try #require(URL(string: "https://example.com/photo.Png"))
    #expect(ImageURLClassifier.isDirectImageURL(urlMixed))
  }

  @Test
  func `Handles URLs with query parameters`() throws {
    let url = try #require(URL(string: "https://example.com/photo.jpg?width=100&height=100"))
    #expect(ImageURLClassifier.isDirectImageURL(url))
  }

  @Test
  func `Rejects URL with no extension`() throws {
    let url = try #require(URL(string: "https://example.com/photo"))
    #expect(!ImageURLClassifier.isDirectImageURL(url))
  }

  @Test
  func `Rejects empty path`() throws {
    let url = try #require(URL(string: "https://example.com/"))
    #expect(!ImageURLClassifier.isDirectImageURL(url))
  }

  // MARK: - GIF Magic Byte Detection

  @Test
  func `Detects GIF87a magic bytes`() {
    let data = Data([0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) // GIF87a
    #expect(ImageURLDetector.isGIFData(data))
  }

  @Test
  func `Detects GIF89a magic bytes`() {
    let data = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]) // GIF89a
    #expect(ImageURLDetector.isGIFData(data))
  }

  @Test
  func `Rejects non-GIF data`() {
    let pngData = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header
    #expect(!ImageURLDetector.isGIFData(pngData))
  }

  @Test
  func `Rejects data shorter than 4 bytes`() {
    let data = Data([0x47, 0x49, 0x46]) // Only 3 bytes
    #expect(!ImageURLDetector.isGIFData(data))
  }

  @Test
  func `Rejects empty data`() {
    #expect(!ImageURLDetector.isGIFData(Data()))
  }

  // MARK: - Downsample

  @Test
  func `downsampledImage honors maxPixelSize`() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)
    let source = renderer.image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    let data = try #require(source.pngData())
    let downsampled = ImageURLDetector.downsampledImage(from: data, maxPixelSize: 32)
    let image = try #require(downsampled)
    #expect(max(image.size.width, image.size.height) <= 32)
  }

  @Test
  func `downsampledImage returns nil for bytes ImageIO cannot decode`() {
    let data = Data("not an image".utf8)
    #expect(ImageURLDetector.downsampledImage(from: data) == nil)
  }

  // MARK: - Animation Decode Budget

  @Test
  func `A typical GIF fits the animation budget`() {
    #expect(ImageURLDetector.fitsAnimationBudget(frameCount: 60, pixelWidth: 480, pixelHeight: 270))
  }

  @Test
  func `Frame count is capped regardless of frame size`() {
    let cap = ImageURLDetector.maxAnimatedFrameCount
    #expect(ImageURLDetector.fitsAnimationBudget(frameCount: cap, pixelWidth: 16, pixelHeight: 16))
    #expect(!ImageURLDetector.fitsAnimationBudget(frameCount: cap + 1, pixelWidth: 16, pixelHeight: 16))
    #expect(!ImageURLDetector.fitsAnimationBudget(frameCount: 50000, pixelWidth: 1, pixelHeight: 1))
  }

  @Test
  func `Total decoded bytes are capped within the frame limit`() {
    // 400 x 400 RGBA is 640_000 bytes a frame: 100 frames are 64_000_000
    // bytes, under the 64 MiB budget, and 105 frames are over it.
    #expect(ImageURLDetector.fitsAnimationBudget(frameCount: 100, pixelWidth: 400, pixelHeight: 400))
    #expect(!ImageURLDetector.fitsAnimationBudget(frameCount: 105, pixelWidth: 400, pixelHeight: 400))
  }

  @Test
  func `Budget is estimated at the downsampled frame size`() {
    // A 4000 x 2000 canvas decodes at 900 x 450 (1_620_000 bytes a frame),
    // so 40 frames fit although 40 full-size frames would be 1.28 GB.
    #expect(ImageURLDetector.fitsAnimationBudget(
      frameCount: 40,
      pixelWidth: 4000,
      pixelHeight: 2000,
      maxPixelSize: 900
    ))
    #expect(!ImageURLDetector.fitsAnimationBudget(
      frameCount: 42,
      pixelWidth: 4000,
      pixelHeight: 2000,
      maxPixelSize: 900
    ))
  }

  @Test
  func `A header with no usable size fails the budget`() {
    #expect(!ImageURLDetector.fitsAnimationBudget(frameCount: 2, pixelWidth: 0, pixelHeight: 100))
    #expect(!ImageURLDetector.fitsAnimationBudget(frameCount: 2, pixelWidth: 100, pixelHeight: -1))
  }

  @Test
  func `decodeGIFImage animates a GIF within the budget`() throws {
    let data = try #require(Self.makeGIF(frameCount: 3, side: 8))
    let image = try #require(ImageURLDetector.decodeGIFImage(from: data))
    #expect(image.images?.count == 3)
  }

  @Test
  func `decodeGIFImage shows only the first frame of a GIF over the frame cap`() throws {
    let frameCount = ImageURLDetector.maxAnimatedFrameCount + 1
    let data = try #require(Self.makeGIF(frameCount: frameCount, side: 8))
    let image = try #require(ImageURLDetector.decodeGIFImage(from: data))
    #expect(image.images == nil)
    #expect(image.cgImage != nil)
  }

  /// Encodes a GIF of `frameCount` solid square frames, each a different gray.
  private static func makeGIF(frameCount: Int, side: Int) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data,
      UTType.gif.identifier as CFString,
      frameCount,
      nil
    ) else {
      return nil
    }
    let frameProperties = [
      kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]
    ] as CFDictionary

    for index in 0..<frameCount {
      guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else {
        return nil
      }
      let gray = CGFloat(index % 256) / 255
      context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: side, height: side))
      guard let frame = context.makeImage() else { return nil }
      CGImageDestinationAddImage(destination, frame, frameProperties)
    }

    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  // MARK: - Giphy URL Resolution

  @Test
  func `Resolves giphy.com/gifs/slug-text-ID`() throws {
    let url = try #require(URL(string: "https://giphy.com/gifs/meme-cute-penguin-UTYwlUGi5iiRHtqEgj"))
    let resolved = ImageURLClassifier.resolveImageURL(url)
    #expect(resolved?.absoluteString == "https://i.giphy.com/media/UTYwlUGi5iiRHtqEgj/giphy.gif")
  }

  @Test
  func `Resolves giphy.com/gifs/ID (no slug)`() throws {
    let url = try #require(URL(string: "https://giphy.com/gifs/UTYwlUGi5iiRHtqEgj"))
    let resolved = ImageURLClassifier.resolveImageURL(url)
    #expect(resolved?.absoluteString == "https://i.giphy.com/media/UTYwlUGi5iiRHtqEgj/giphy.gif")
  }

  @Test
  func `Resolves giphy.com/embed/ID`() throws {
    let url = try #require(URL(string: "https://giphy.com/embed/UTYwlUGi5iiRHtqEgj"))
    let resolved = ImageURLClassifier.resolveImageURL(url)
    #expect(resolved?.absoluteString == "https://i.giphy.com/media/UTYwlUGi5iiRHtqEgj/giphy.gif")
  }

  @Test
  func `Recognizes media.giphy.com as direct image URL`() throws {
    let url = try #require(URL(string: "https://media.giphy.com/media/UTYwlUGi5iiRHtqEgj/giphy.gif"))
    #expect(ImageURLClassifier.isDirectImageURL(url), "Should be detected as direct image URL via .gif extension")
  }

  @Test
  func `Recognizes i.giphy.com as direct image URL`() throws {
    let url = try #require(URL(string: "https://i.giphy.com/media/UTYwlUGi5iiRHtqEgj/giphy.gif"))
    #expect(ImageURLClassifier.isDirectImageURL(url), "Should be detected as direct image URL via .gif extension")
  }

  @Test
  func `Returns nil for non-Giphy URLs`() throws {
    let url = try #require(URL(string: "https://example.com/gifs/test-123"))
    #expect(ImageURLClassifier.resolveImageURL(url) == nil)
  }

  @Test
  func `Returns nil for Giphy URLs without valid path`() throws {
    let url = try #require(URL(string: "https://giphy.com/"))
    #expect(ImageURLClassifier.resolveImageURL(url) == nil)
  }

  @Test
  func `Resolves www.giphy.com URLs`() throws {
    let url = try #require(URL(string: "https://www.giphy.com/gifs/test-ID123"))
    let resolved = ImageURLClassifier.resolveImageURL(url)
    #expect(resolved?.absoluteString == "https://i.giphy.com/media/ID123/giphy.gif")
  }

  // MARK: - Composite Detection

  @Test
  func `isImageURL returns true for direct image URLs`() throws {
    let url = try #require(URL(string: "https://example.com/photo.png"))
    #expect(ImageURLClassifier.isImageURL(url))
  }

  @Test
  func `isImageURL returns true for resolvable Giphy URLs`() throws {
    let url = try #require(URL(string: "https://giphy.com/gifs/test-ABC123"))
    #expect(ImageURLClassifier.isImageURL(url))
  }

  @Test
  func `isImageURL returns false for non-image URLs`() throws {
    let url = try #require(URL(string: "https://example.com/page.html"))
    #expect(!ImageURLClassifier.isImageURL(url))
  }

  @Test
  func `directImageURL returns self for direct images`() throws {
    let url = try #require(URL(string: "https://example.com/photo.jpg"))
    #expect(ImageURLClassifier.directImageURL(for: url) == url)
  }

  @Test
  func `directImageURL resolves Giphy URLs`() throws {
    let url = try #require(URL(string: "https://giphy.com/gifs/funny-ABC123"))
    let resolved = ImageURLClassifier.directImageURL(for: url)
    #expect(resolved.absoluteString == "https://i.giphy.com/media/ABC123/giphy.gif")
  }
}
