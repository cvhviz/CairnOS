import CoreGraphics
import Foundation

/// Prefetch cache key and snapshot size from the Path Details container width.
enum MessagePathPreviewSnapshot {
  static let widthBucketPoints: CGFloat = 8
  static let expandedHorizontalPadding: CGFloat = 16

  struct Key: Hashable {
    let arrivalID: UUID
    let isDark: Bool
    let isOffline: Bool
    let widthBucket: Int
    /// The avatar appearance the hop pins were drawn in, so a theme or contrast change re-renders.
    let appearance: String
  }

  static func bucketedWidth(_ width: CGFloat) -> Int {
    Int((width / widthBucketPoints).rounded() * widthBucketPoints)
  }

  static func previewSize(containerWidth: CGFloat) -> CGSize {
    let inner = max(0, containerWidth - 2 * expandedHorizontalPadding)
    return CGSize(
      width: CGFloat(bucketedWidth(inner)),
      height: MessagePathPreviewMap.previewHeight
    )
  }

  static func key(
    arrivalID: UUID,
    isDark: Bool,
    isOffline: Bool,
    containerWidth: CGFloat,
    appearance: MapAvatarAppearance? = nil
  ) -> Key {
    let inner = max(0, containerWidth - 2 * expandedHorizontalPadding)
    return Key(
      arrivalID: arrivalID,
      isDark: isDark,
      isOffline: isOffline,
      widthBucket: bucketedWidth(inner),
      appearance: (appearance ?? .standard(isDark: isDark)).fingerprint
    )
  }
}
