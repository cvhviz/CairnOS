import CoreImage
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A photo saved as the page background.
struct SavedBackgroundImage: Equatable, Sendable {
  let fileName: String
  let averageColor: BackgroundColor
}

/// Keeps the background photo on disk in Application Support, never in `UserDefaults`.
///
/// A picked photo is downscaled to at most `maxPixelSize` on its long side and re-encoded as
/// JPEG: a page background never needs more than a screen's worth of pixels, and a full-size
/// camera original would cost tens of megabytes of memory every time a page draws it. Blurred
/// renders are cached next to it, keyed by radius, so a cold launch never re-blurs.
struct BackgroundImageStore: Sendable {
  let directory: URL

  static let maxPixelSize = 2048
  static let jpegQuality: CGFloat = 0.85
  static let filePrefix = "background-"
  static let fileExtension = "jpg"

  enum StoreError: Error, Equatable {
    case unreadableImage
    case encodingFailed
  }

  /// `Application Support/Backgrounds`.
  static let `default`: BackgroundImageStore = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return BackgroundImageStore(directory: base.appendingPathComponent("Backgrounds", isDirectory: true))
  }()

  /// Only names this store mints are accepted, so a file name restored from a backup can never
  /// point outside the store's directory.
  static func isValidFileName(_ name: String) -> Bool {
    name.hasPrefix(filePrefix)
      && name.hasSuffix(".\(fileExtension)")
      && !name.contains("/")
      && !name.contains("..")
      && name.count <= 128
  }

  func fileURL(named name: String) -> URL? {
    guard Self.isValidFileName(name) else { return nil }
    return directory.appendingPathComponent(name, isDirectory: false)
  }

  func contains(named name: String) -> Bool {
    guard let url = fileURL(named: name) else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  /// Decodes lazily: the pixels load the first time the image draws.
  func image(named name: String) -> UIImage? {
    guard let url = fileURL(named: name) else { return nil }
    return UIImage(contentsOfFile: url.path)
  }

  /// Downscales, re-encodes and saves the photo under a fresh name. The caller deletes the
  /// previous photo once the new one is in use.
  func save(imageData: Data) throws -> SavedBackgroundImage {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
      throw StoreError.unreadableImage
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      // Bakes the EXIF orientation into the pixels, so the saved JPEG needs no metadata.
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw StoreError.unreadableImage
    }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = "\(Self.filePrefix)\(UUID().uuidString).\(Self.fileExtension)"
    let url = directory.appendingPathComponent(name, isDirectory: false)
    try Self.writeJPEG(image, to: url)
    return SavedBackgroundImage(fileName: name, averageColor: Self.averageColor(of: image))
  }

  /// Deletes a photo and every blurred render cached for it.
  func delete(named name: String) {
    guard let url = fileURL(named: name) else { return }
    try? FileManager.default.removeItem(at: url)
    removeBlurRenders(of: name, except: nil)
  }

  /// Deletes every stored photo and render except `name` and its renders (a picked-then-replaced
  /// photo, or a file left behind when the app quit mid-change).
  func removeAll(except name: String?) {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    let keepStem = name.map(Self.stem(of:))
    for file in files where keepStem.map({ !file.hasPrefix($0) }) ?? true {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
    }
  }

  // MARK: Blur renders

  /// The cached render of `name` at a whole-point blur radius, if one has been made.
  func blurRender(of name: String, radius: Int) -> UIImage? {
    guard let url = blurRenderURL(of: name, radius: radius),
          FileManager.default.fileExists(atPath: url.path) else { return nil }
    return UIImage(contentsOfFile: url.path)
  }

  /// Blurs the photo, caches the render on disk and drops renders at other radii. Runs on the
  /// caller's thread; call it off the main actor.
  func makeBlurRender(of name: String, radius: Int) throws -> UIImage {
    guard let url = fileURL(named: name),
          let renderURL = blurRenderURL(of: name, radius: radius),
          let source = CIImage(contentsOf: url) else {
      throw StoreError.unreadableImage
    }
    guard let blurred = Self.blur(source, radius: radius) else { throw StoreError.encodingFailed }
    try Self.writeJPEG(blurred, to: renderURL)
    removeBlurRenders(of: name, except: radius)
    return UIImage(cgImage: blurred)
  }

  private func blurRenderURL(of name: String, radius: Int) -> URL? {
    guard Self.isValidFileName(name) else { return nil }
    return directory.appendingPathComponent("\(Self.stem(of: name))-blur\(radius).\(Self.fileExtension)")
  }

  private func removeBlurRenders(of name: String, except radius: Int?) {
    let prefix = "\(Self.stem(of: name))-blur"
    let keep = radius.flatMap { blurRenderURL(of: name, radius: $0)?.lastPathComponent }
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for file in files where file.hasPrefix(prefix) && file != keep {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
    }
  }

  private static func stem(of name: String) -> String {
    String(name.dropLast(fileExtension.count + 1))
  }

  // MARK: Image processing

  private static let ciContext = CIContext(options: [.cacheIntermediates: false])

  /// Longest side a blurred render keeps. Blur removes the detail the extra pixels would carry.
  private static let blurRenderMaxPixelSize: CGFloat = 1024
  /// Page width (points) the blur radius is defined against: the slider's points are the points
  /// of a phone-sized page showing the photo aspect-filled.
  private static let referencePageWidth: CGFloat = 400

  static func blur(_ source: CIImage, radius: Int) -> CGImage? {
    let extent = source.extent
    let longSide = max(extent.width, extent.height)
    let scale = min(1, blurRenderMaxPixelSize / max(longSide, 1))
    let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let pixelsPerPoint = min(scaled.extent.width, scaled.extent.height) / referencePageWidth
    let blurred = scaled
      .clampedToExtent()
      .applyingGaussianBlur(sigma: Double(CGFloat(radius) * pixelsPerPoint))
      .cropped(to: scaled.extent)
    return ciContext.createCGImage(blurred, from: scaled.extent)
  }

  private static func writeJPEG(_ image: CGImage, to url: URL) throws {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw StoreError.encodingFailed
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw StoreError.encodingFailed }
    try (data as Data).write(to: url, options: .atomic)
  }

  /// Average color via Core Image's area average, rendered into one sRGB pixel.
  static func averageColor(of image: CGImage) -> BackgroundColor {
    let input = CIImage(cgImage: image)
    let average = input.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: input.extent)])
    var pixel = [UInt8](repeating: 0, count: 4)
    ciContext.render(
      average,
      toBitmap: &pixel,
      rowBytes: 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
    )
    return BackgroundColor(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
  }
}
