import Foundation
import ImageIO
import UIKit

/// Inline image decoding (UIKit/ImageIO). For URL classification, use
/// `CairnServices.ImageURLClassifier`.
enum ImageURLDetector {
  /// Max pixel dimension for inline image display (280pt × 3x scale)
  private static let inlineMaxPixelSize: CGFloat = 900

  /// Decode budget for an animated GIF. Every frame is decoded and held for
  /// the life of the image, so without a bound a small file carrying
  /// thousands of frames decodes into gigabytes.
  static let maxAnimatedFrameCount = 150
  static let maxAnimatedDecodedBytes = 64 * 1024 * 1024
  private static let bytesPerPixelRGBA = 4

  /// Decodes an image at a reduced size using ImageIO, avoiding full-resolution decode.
  /// Returns `nil` if thumbnail generation fails: the data comes from the network, and
  /// `UIImage(data:)` would decode it at full size with no bound.
  static func downsampledImage(from data: Data, maxPixelSize: CGFloat = inlineMaxPixelSize) -> UIImage? {
    let options: [CFString: Any] = [
      kCGImageSourceShouldCache: false
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
      return nil
    }
    let downsampleOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
      return nil
    }
    return UIImage(cgImage: cgImage)
  }

  /// Whether an animation's frames fit the decode budget, judged from the
  /// header alone so nothing is decoded to find out. Frames are downsampled
  /// to `maxPixelSize` on decode, so the estimate uses the downsampled size.
  static func fitsAnimationBudget(
    frameCount: Int,
    pixelWidth: Int,
    pixelHeight: Int,
    maxPixelSize: CGFloat = inlineMaxPixelSize
  ) -> Bool {
    guard frameCount <= maxAnimatedFrameCount, pixelWidth > 0, pixelHeight > 0 else { return false }
    let scale = min(1, Double(maxPixelSize) / Double(max(pixelWidth, pixelHeight)))
    let frameBytes = Double(pixelWidth) * scale * Double(pixelHeight) * scale * Double(bytesPerPixelRGBA)
    return frameBytes * Double(frameCount) <= Double(maxAnimatedDecodedBytes)
  }

  /// Returns `true` if the data begins with the GIF magic bytes (`GIF8`)
  static func isGIFData(_ data: Data) -> Bool {
    guard data.count >= 4 else { return false }
    return data[data.startIndex] == 0x47 // G
      && data[data.startIndex + 1] == 0x49 // I
      && data[data.startIndex + 2] == 0x46 // F
      && data[data.startIndex + 3] == 0x38 // 8
  }

  /// Decodes GIF data into an animated UIImage using CGImageSource.
  /// Returns `nil` if the data is not valid GIF data.
  static func decodeGIFImage(from data: Data) -> UIImage? {
    guard isGIFData(data),
          let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return nil
    }

    let count = CGImageSourceGetCount(source)
    guard count > 1 else {
      return downsampledImage(from: data)
    }

    // Over budget, or with no readable size to budget against, show the first frame only.
    let headerProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    guard let pixelWidth = headerProperties?[kCGImagePropertyPixelWidth] as? Int,
          let pixelHeight = headerProperties?[kCGImagePropertyPixelHeight] as? Int,
          fitsAnimationBudget(frameCount: count, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
      return downsampledImage(from: data)
    }

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: inlineMaxPixelSize,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true
    ]

    var frames: [UIImage] = []
    var totalDuration: TimeInterval = 0

    for i in 0..<count {
      guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, i, thumbnailOptions as CFDictionary) else { continue }
      frames.append(UIImage(cgImage: cgImage))

      let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
      let gifDict = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
      let delay = gifDict?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        ?? gifDict?[kCGImagePropertyGIFDelayTime] as? Double
        ?? 0.1
      totalDuration += max(delay, 0.02)
    }

    guard !frames.isEmpty else { return nil }
    return UIImage.animatedImage(with: frames, duration: totalDuration)
  }
}
