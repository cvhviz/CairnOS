import CairnServices
import ImageIO
import SwiftUI
import UIKit

/// The appearance node pins resolve their avatar colours in: the app's theme, light or dark, and
/// Increase Contrast, read from the same environment the avatar views read. A change re-renders
/// every node pin, since each sprite name carries it.
struct MapAvatarAppearance: Equatable {
  var theme: Theme
  var colorScheme: ColorScheme
  var contrast: ColorSchemeContrast

  /// Cairn's palette in a light or dark appearance at standard contrast, for callers with no
  /// SwiftUI environment (snapshots).
  static func standard(isDark: Bool) -> MapAvatarAppearance {
    MapAvatarAppearance(theme: .default, colorScheme: isDark ? .dark : .light, contrast: .standard)
  }

  /// Short, name-safe tag for the sprite key: the theme, then light or dark, then contrast.
  var fingerprint: String {
    let scheme = colorScheme == .dark ? "d" : "l"
    let contrastTag = contrast == .increased ? "h" : "s"
    return "\(PinAvatarSprite.stableHash(theme.id))\(scheme)\(contrastTag)"
  }

  static func == (lhs: MapAvatarAppearance, rhs: MapAvatarAppearance) -> Bool {
    lhs.theme.id == rhs.theme.id
      && lhs.colorScheme == rhs.colorScheme
      && lhs.contrast == rhs.contrast
  }
}

/// A node pin drawn as that node's avatar, as `ContactAvatar` and `NodeAvatar` draw it: the photo,
/// the emoji a name leads with, or the walkie-talkie, mast or door, on the avatar's colour, in a
/// pebble head over a pointer tail. Built from a `MapPoint`; `spriteName` names it uniquely, so
/// the map can ask for it again by name after an atlas eviction.
struct PinAvatarSprite {
  enum Kind: String {
    case chat
    case repeater
    case room
  }

  /// The LOS and trace selection rings around a repeater's head.
  enum Ring: String {
    case blue
    case green
    /// A trace's hops: named for the white it once was, which vanished on pale maps. Now Trace
    /// Path's own amber.
    case white

    var color: UIColor {
      switch self {
      case .blue: .systemBlue
      case .green: .systemGreen
      case .white: .systemOrange
      }
    }
  }

  static let namePrefix = "pin-avatar-"

  let kind: Kind
  /// A companion's name, whose leading emoji it shows. Nil when no avatar is known, only the type.
  let name: String?
  /// One of the user's own radios: the radio colour instead of the companions'.
  let isRadio: Bool
  let photo: Data?
  let photoRevision: UInt64?
  /// The colour picked for the node, or nil for Automatic (its category's colour).
  let color: NodeAvatarColor?
  /// A node heard but not saved: white head, ring and glyph in the avatar colour, never a photo.
  let isOutlined: Bool
  let ring: Ring?
  let hopIndex: Int?
  let appearance: MapAvatarAppearance

  /// The avatar sprite for a node pin, or nil for a pin that isn't a node (points, crosshair,
  /// dropped pin, location fixes, badges).
  init?(point: MapPoint, appearance: MapAvatarAppearance) {
    var ring: Ring?
    var hop: Int?
    var isOutlined = false
    let kind: Kind
    switch point.pinStyle {
    case .contactChat: kind = .chat
    case .contactRepeater, .repeater: kind = .repeater
    case .contactRoom: kind = .room
    case .discoveredChat: kind = .chat; isOutlined = true
    case .discoveredRepeater: kind = .repeater; isOutlined = true
    case .discoveredRoom: kind = .room; isOutlined = true
    case .repeaterRingBlue: kind = .repeater; ring = .blue
    case .repeaterRingGreen: kind = .repeater; ring = .green
    case .repeaterRingWhite: kind = .repeater; ring = .white; hop = point.hopIndex
    case .repeaterHop: kind = .repeater; hop = point.hopIndex
    case .pointA, .pointB, .crosshair, .obstruction, .badge, .droppedPin, .locationFix, .locationFixLatest:
      return nil
    }
    self.kind = kind
    self.isOutlined = isOutlined
    self.ring = ring
    hopIndex = hop.map { min(max($0, 1), PinSpriteRenderer.maxHopBadge) }
    self.appearance = appearance
    // Only a companion's emoji follows its name; every node takes its category's colour unless
    // one was picked. Any saved node can carry a photo.
    if let avatar = point.avatar {
      name = kind == .chat ? avatar.name : nil
      isRadio = kind == .chat && avatar.isRadio
      let photo = isOutlined ? nil : avatar.photo
      self.photo = photo
      photoRevision = photo == nil ? nil : avatar.photoRevision
      color = avatar.color
    } else {
      name = nil
      isRadio = false
      photo = nil
      photoRevision = nil
      color = nil
    }
  }

  /// "pin-avatar-<kind>[-radio][-outlined][-ring-<colour>][-hop-<n>]-<appearance>[-n<name hash>][-c<colour>][-p<photo>]".
  /// Stable for the same avatar in the same appearance, so equal pins share one sprite.
  var spriteName: String {
    var parts = [kind.rawValue]
    if isRadio { parts.append("radio") }
    if isOutlined { parts.append("outlined") }
    if let ring { parts.append("ring-\(ring.rawValue)") }
    if let hopIndex { parts.append("hop-\(hopIndex)") }
    parts.append(appearance.fingerprint)
    if let name { parts.append("n" + Self.stableHash(name)) }
    if let color { parts.append("c" + color.rawValue) }
    if let photoRevision { parts.append("p" + String(photoRevision, radix: 16)) }
    return Self.namePrefix + parts.joined(separator: "-")
  }

  /// FNV-1a over the UTF-8 bytes, in hex: the same for the same text in every run, unlike `Hasher`.
  static func stableHash(_ text: String) -> String {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01B3
    }
    return String(hash, radix: 16)
  }
}

// MARK: - Drawing

extension PinAvatarSprite {
  /// Side of the pebble head, as the circle head was before.
  static let headSize: CGFloat = 36
  static let tailSize: CGFloat = 10
  /// How far the tail tucks under the head.
  static let tailOverlap: CGFloat = 3
  static let rimWidth: CGFloat = 1.5
  private static let ringSize: CGFloat = 50
  /// How far the ring rises above the head; the tail's tip reaches its bottom edge.
  private static let ringPadding: CGFloat = 7

  /// The avatar's fill and glyph colours, resolved as the avatar views resolve them.
  @MainActor
  func colors() -> (fill: UIColor, glyph: UIColor) {
    let theme = appearance.theme
    let scheme = appearance.colorScheme
    let contrast = appearance.contrast
    let traits = Theme.traitCollection(colorScheme: scheme, contrast: contrast)
    let fill: Color
    if let color {
      // A picked colour fills the head (or, under a photo, still tints the tail and name badge).
      fill = theme.swatchFill(color, colorScheme: scheme, contrast: contrast)
      let glyph = theme.avatarGlyphColor(forFill: fill, swatch: color, colorScheme: scheme, contrast: contrast)
      return (UIColor(fill).resolvedColor(with: traits), UIColor(glyph).resolvedColor(with: traits))
    }
    let category: AvatarCategory = switch kind {
    case .chat: isRadio ? .radio : .companion
    case .repeater: .repeater
    case .room: .room
    }
    fill = category.color
    let glyph = theme.avatarGlyphColor(forFill: fill, swatch: nil, colorScheme: scheme, contrast: contrast)
    return (UIColor(fill).resolvedColor(with: traits), UIColor(glyph).resolvedColor(with: traits))
  }

  /// The pin: the ring when selected, the tail, the head (rim, then the avatar) and the hop badge.
  @MainActor
  func render() -> UIImage {
    let (fill, glyphColor) = colors()
    let headSize = Self.headSize
    let ringPadding: CGFloat = ring != nil ? Self.ringPadding : 0
    // A hop badge overhangs the head's right edge by 4pt; widen the canvas symmetrically so the
    // tail's tip stays centred on the coordinate.
    let badgeRoom: CGFloat = hopIndex != nil ? 44 : 0
    let width = max(headSize, ring != nil ? Self.ringSize : 0, badgeRoom)
    let height = headSize + Self.tailSize - Self.tailOverlap + ringPadding
    let photoImage = photo.flatMap { Self.thumbnail(of: $0, revision: photoRevision, side: headSize) }

    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: .preferred()).image { ctx in
      let cg = ctx.cgContext
      let centerX = width / 2
      let headRect = CGRect(x: centerX - headSize / 2, y: ringPadding, width: headSize, height: headSize)

      if let ring {
        let ringRect = CGRect(
          x: centerX - Self.ringSize / 2,
          y: headRect.midY - Self.ringSize / 2,
          width: Self.ringSize,
          height: Self.ringSize
        )
        // Reads on any basemap, as a road sign does: a wash of its colour behind the pin, then its
        // colour on a white casing with a dark hairline outside that.
        ring.color.withAlphaComponent(0.32).setFill()
        cg.fillEllipse(in: ringRect)
        UIColor.black.withAlphaComponent(0.3).setStroke()
        cg.setLineWidth(1)
        cg.strokeEllipse(in: ringRect.insetBy(dx: 0.5, dy: 0.5))
        UIColor.white.setStroke()
        cg.setLineWidth(6)
        cg.strokeEllipse(in: ringRect.insetBy(dx: 4, dy: 4))
        ring.color.setStroke()
        cg.setLineWidth(3.5)
        cg.strokeEllipse(in: ringRect.insetBy(dx: 4, dy: 4))
      }

      let tailTop = headRect.maxY - Self.tailOverlap
      let tail = UIBezierPath()
      tail.move(to: CGPoint(x: centerX - Self.tailSize / 2, y: tailTop))
      tail.addLine(to: CGPoint(x: centerX + Self.tailSize / 2, y: tailTop))
      tail.addLine(to: CGPoint(x: centerX, y: tailTop + Self.tailSize))
      tail.close()
      let head = Self.pebble(headRect)

      // Tail and white head under one soft shadow, so the pin reads on any basemap.
      cg.saveGState()
      cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.3).cgColor)
      cg.beginTransparencyLayer(auxiliaryInfo: nil)
      fill.setFill()
      tail.fill()
      UIColor.white.setFill()
      head.fill()
      cg.endTransparencyLayer()
      cg.restoreGState()

      let inner = headRect.insetBy(dx: Self.rimWidth, dy: Self.rimWidth)
      if isOutlined {
        // Heard, not saved: the white head keeps the outlined look, ringed in the avatar colour.
        fill.setStroke()
        let ringPath = Self.pebble(headRect.insetBy(dx: 1.5, dy: 1.5))
        ringPath.lineWidth = 3
        ringPath.stroke()
        drawGlyph(color: fill, in: headRect, scale: 0.86)
      } else if let photoImage {
        cg.saveGState()
        Self.pebble(inner).addClip()
        let image = photoImage.size
        let fillScale = max(inner.width / max(image.width, 1), inner.height / max(image.height, 1))
        let drawn = CGSize(width: image.width * fillScale, height: image.height * fillScale)
        photoImage.draw(in: CGRect(
          x: inner.midX - drawn.width / 2,
          y: inner.midY - drawn.height / 2,
          width: drawn.width,
          height: drawn.height
        ))
        cg.restoreGState()
      } else {
        cg.saveGState()
        Self.pebble(inner).addClip()
        if appearance.contrast == .increased {
          fill.setFill()
          cg.fill(inner)
        } else {
          // AvatarDisc's soft top-lit gradient over the avatar colour.
          let top = fill.mixed(with: .white, amount: 0.14)
          if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [top.cgColor, fill.cgColor] as CFArray,
            locations: [0, 1]
          ) {
            cg.drawLinearGradient(gradient, start: CGPoint(x: inner.midX, y: inner.minY), end: CGPoint(x: inner.midX, y: inner.maxY), options: [])
          }
        }
        cg.restoreGState()
        drawGlyph(color: glyphColor, in: headRect, scale: 1)
      }

      if let hopIndex {
        let badgeSize: CGFloat = 18
        let badgeRect = CGRect(x: headRect.maxX + 4 - badgeSize, y: headRect.minY, width: badgeSize, height: badgeSize)
        UIColor.systemBlue.setFill()
        cg.fillEllipse(in: badgeRect)
        let text = "\(hopIndex)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
          .font: UIFont.systemFont(ofSize: 11, weight: .bold),
          .foregroundColor: UIColor.white,
        ]
        let textSize = text.size(withAttributes: attrs)
        text.draw(
          in: CGRect(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
          ),
          withAttributes: attrs
        )
      }
    }
  }

  /// The avatar's glyph centred in the head, sized as the avatar views size theirs against the
  /// side: the emoji 0.4, the walkie-talkie 0.42, the mast 0.56 and the door 0.45.
  private func drawGlyph(color: UIColor, in headRect: CGRect, scale: CGFloat) {
    let side = headRect.width
    if kind == .chat, let emoji = name.flatMap({ CarPlayAvatar.emoji(CarPlayAvatar.companion($0)) }) {
      let text = NSAttributedString(
        string: emoji,
        attributes: [.font: UIFont.systemFont(ofSize: side * 0.4 * scale, weight: .semibold)]
      )
      let size = text.size()
      text.draw(at: CGPoint(x: headRect.midX - size.width / 2, y: headRect.midY - size.height / 2))
      return
    }
    let symbol: String
    let share: CGFloat
    switch kind {
    case .chat: symbol = CarPlayAvatar.companionSymbol; share = 0.42
    case .repeater: symbol = CarPlayAvatar.repeaterSymbol; share = 0.56
    case .room: symbol = CarPlayAvatar.roomSymbol; share = 0.45
    }
    let config = UIImage.SymbolConfiguration(pointSize: side * share * scale, weight: .semibold)
    guard let image = (UIImage(systemName: symbol, withConfiguration: config)
      ?? UIImage(named: symbol, in: .main, with: config))?
      .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
    let box = side * 0.7 * scale
    let fit = min(1, box / max(image.size.width, 1), box / max(image.size.height, 1))
    let drawn = CGSize(width: image.size.width * fit, height: image.size.height * fit)
    image.draw(in: CGRect(
      x: headRect.midX - drawn.width / 2,
      y: headRect.midY - drawn.height / 2,
      width: drawn.width,
      height: drawn.height
    ))
  }

  /// `AvatarPebble`'s own outline, so the head is the same squircle as every avatar. (UIKit's
  /// rounded rect turns into a circle at this corner fraction.)
  static func pebble(_ rect: CGRect) -> UIBezierPath {
    UIBezierPath(cgPath: AvatarPebble().path(in: rect).cgPath)
  }

  /// Downscaled photos by revision, so a pin never decodes a full-size JPEG twice.
  @MainActor private static let thumbnails: NSCache<NSNumber, UIImage> = {
    let cache = NSCache<NSNumber, UIImage>()
    cache.countLimit = 128
    return cache
  }()

  /// The photo decoded straight to a few times the head's pixel size (ImageIO thumbnailing), so a
  /// large JPEG is never decoded whole.
  @MainActor
  static func thumbnail(of data: Data, revision: UInt64?, side: CGFloat) -> UIImage? {
    let key = revision.map { NSNumber(value: $0) }
    if let key, let cached = thumbnails.object(forKey: key) { return cached }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let scale = UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 3
    // Twice the head on its long side, so an aspect fill still covers the head after cropping.
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: Int((side * scale * 2).rounded(.up)),
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let image = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    if let key { thumbnails.setObject(image, forKey: key) }
    return image
  }
}

private extension UIColor {
  /// This colour moved `amount` of the way toward `other`.
  func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
    var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
          other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return self }
    return UIColor(
      red: r1 + (r2 - r1) * amount,
      green: g1 + (g2 - g1) * amount,
      blue: b1 + (b2 - b1) * amount,
      alpha: a1 + (a2 - a1) * amount
    )
  }
}
