import MapLibre
import UIKit

@MainActor
enum PinSpriteRenderer {
  /// Height of a standard pin sprite in points (head + triangle pointer), the same for the
  /// circle-headed pins and the pebble-headed avatar pins. Used by the map Coordinator to
  /// position callout anchors above the pin icon.
  static let standardHeight: CGFloat = 43 // 36 (head) + 10 (triangle) - 3 (overlap)

  /// Diameter of the small center-anchored location-fix dot.
  static let locationDotDiameter: CGFloat = 14

  /// Number of recency buckets a location trail's dots are graded into. Five reads
  /// as a clear directional gradient without banding into noise at dot size.
  /// `nonisolated` so the (non-isolated) path builder can bucket against it.
  nonisolated static let recencyBucketCount = 5

  /// Recency ramp for sampled location-fix dots, oldest → newest: a warm "ember"
  /// family (warm-grey → ochre → amber → orange → coral) that harmonizes with the
  /// pink hero while stopping short of its hue, so the newest dot is never mistaken
  /// for the current-position hero. Tuned per basemap because a single ramp can't
  /// stay legible on both: the light stops would sink into a dark ground, and vice
  /// versa. Recency rises in saturation and warmth together, so it survives greyscale
  /// and red/green colour-vision deficiency. From an Apple UI/UX design consult.
  private static let locationDotPaletteLight = [0xA19687, 0xB68F68, 0xD17A47, 0xE76740, 0xF55E47].map(hexColor)
  private static let locationDotPaletteDark = [0xB1A695, 0xC59E77, 0xD8885A, 0xED7C5A, 0xF87662].map(hexColor)

  /// The hero tint for the node's latest location report (the mockup's `--hero`).
  private static let locationHeroColor = hexColor(0xFF375F)

  /// Sprite name for a location-fix dot at the given recency bucket (clamped in range).
  static func locationDotSpriteName(bucket: Int) -> String {
    "pin-location-fix-\(min(max(bucket, 0), recencyBucketCount - 1))"
  }

  private nonisolated static func hexColor(_ hex: UInt32) -> UIColor {
    UIColor(
      red: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1
    )
  }

  /// Upward offset from a pin's coordinate to where its tap callout should attach:
  /// the top of the drawn sprite. Bottom-anchored teardrops lift a full pin height;
  /// the center-anchored location dot lifts only its radius plus a hair of clearance.
  static func calloutLift(for style: MapPoint.PinStyle) -> CGFloat {
    switch style {
    case .locationFix: locationDotDiameter / 2 + 4
    // A badge has no pin to clear: the only callout on one is a Traffic link's, pointing at the line.
    case .badge: 6
    // Repeaters stand as masts, taller than the teardrops; the callout points at the beacon.
    case .contactRepeater, .repeater, .repeaterRingBlue, .repeaterRingGreen, .repeaterRingWhite,
         .repeaterHop, .discoveredRepeater: RepeaterMastSprite.isEnabled ? RepeaterMastSprite.calloutLift : standardHeight
    default: standardHeight
    }
  }

  nonisolated static let labelSpritePrefix = "label-"

  /// Largest hop number a pin badge will render. Hops beyond this clamp to the
  /// cap rather than failing to resolve a sprite. MeshCore paths top out at 64 hops.
  nonisolated static let maxHopBadge = 64

  private static var cachedImages: [String: UIImage]?

  /// Sprites cached for static snapshot compositing, keyed by spec name. Distinct
  /// from `cachedImages`, which is only populated after the Map tab loads its GL
  /// style; the snapshot render paths never load that style.
  private static var cachedSnapshotSprites: [String: UIImage] = [:]

  /// A base pin sprite rendered once and reused, so snapshot thumbnails composite
  /// the exact pins the live map drops. Unknown names return an empty image.
  static func snapshotSprite(named name: String) -> UIImage {
    if let cached = cachedSnapshotSprites[name] { return cached }
    if let avatar = avatarSprite(named: name) { return avatar }
    if let mast = mastSprite(named: name) { return mast }
    guard let spec = allSpecs.first(where: { $0.name == name }) else { return UIImage() }
    let image = render(spec)
    cachedSnapshotSprites[name] = image
    return image
  }

  /// The snapshot sprite for a pin: a repeater's mast, its node's avatar, or the named base sprite.
  static func snapshotSprite(for point: MapPoint, appearance: MapAvatarAppearance, fallbackName: String) -> UIImage {
    if let mast = RepeaterMastSprite(point: point, appearance: appearance) {
      return snapshotSprite(named: register(mast))
    }
    if let avatar = PinAvatarSprite(point: point, appearance: appearance) {
      return snapshotSprite(named: register(avatar))
    }
    return snapshotSprite(named: fallbackName)
  }

  /// The ground shadow a snapshot draws centred under a repeater's mast, or nil for other pins.
  static func snapshotGroundSprite(for point: MapPoint, appearance: MapAvatarAppearance) -> UIImage? {
    guard let mast = RepeaterMastSprite(point: point, appearance: appearance) else { return nil }
    register(mast)
    return mastSprite(named: mast.groundSpriteName)
  }

  /// The dropped-pin sprite (systemPink circle + `mappin`) for the chat map thumbnail.
  static func droppedPinSprite() -> UIImage {
    snapshotSprite(named: "pin-dropped")
  }

  /// Registers base pin sprites. Node avatar and name-label sprites load lazily via
  /// `renderOnDemand` / `image(named:)`. `isDarkMode` picks the location-dot palette.
  static func renderAll(into style: MLNStyle, isDarkMode: Bool) {
    var rendered: [String: UIImage] = [:]
    for spec in allSpecs {
      rendered[spec.name] = render(spec)
    }
    // Recency-graded location dots: one sprite per bucket, from the theme's palette.
    let palette = isDarkMode ? locationDotPaletteDark : locationDotPaletteLight
    // A pure-white casing on every small dot over a dark basemap sparkles and starts
    // borrowing the hero's white-centre language, so soften it on dark ground.
    let casing = isDarkMode ? UIColor.white.withAlphaComponent(0.85) : UIColor.white
    for bucket in 0..<recencyBucketCount {
      rendered[locationDotSpriteName(bucket: bucket)] = renderLocationDot(fill: palette[bucket], casing: casing)
    }
    rendered["pin-badge"] = UIGraphicsImageRenderer(
      size: CGSize(width: 1, height: 1), format: .preferred()
    ).image { _ in }
    rendered["pill-bg"] = renderPillBackground()
    for selected in [false, true] {
      rendered[RepeaterMastSprite.warningLightName(selected: selected)] = RepeaterMastSprite.renderWarningLight(selected: selected)
    }
    cachedImages = rendered

    for (name, image) in rendered {
      style.setImage(image, forName: name)
    }
  }

  /// Keep label, pin, and pill-bg sprites across source replaces. Basemap sprites still evict.
  static func shouldRetainStyleImage(_ name: String) -> Bool {
    name == "pill-bg"
      || name.hasPrefix(labelSpritePrefix)
      || name.hasPrefix("pin-")
  }

  /// Cached node avatar or name-label sprite for `didFailToLoadImage` to register once.
  static func image(named name: String) -> UIImage? {
    if let cached = cachedImages?[name] {
      return cached
    }
    if let avatar = avatarSprite(named: name) {
      return avatar
    }
    if let mast = mastSprite(named: name) {
      return mast
    }
    guard let badge = MapLabelBadge(spriteName: name) else { return nil }
    let image = renderBadgeCard(badge)
    cachedImages?[name] = image
    return image
  }

  /// Registers the sprite only when the style does not already have it, so a
  /// source replace neither rebuilds the image atlas nor redraws a sprite the style holds.
  @discardableResult
  static func renderOnDemand(name: String, into style: MLNStyle) -> UIImage? {
    if let existing = style.image(forName: name) { return existing }
    guard let image = image(named: name) else { return nil }
    style.setImage(image, forName: name)
    return image
  }

  // MARK: - Sprite names

  /// The sprite a pin draws: a repeater's mast (`RepeaterMastSprite`), a node's avatar
  /// (`PinAvatarSprite`), both registered here so they can be rendered again by name, else the
  /// base sprite for its style. `isSelected` draws a mast at its selected size.
  static func spriteName(for point: MapPoint, appearance: MapAvatarAppearance, isSelected: Bool = false) -> String {
    if let mast = RepeaterMastSprite(point: point, appearance: appearance, isSelected: isSelected) {
      return register(mast)
    }
    if let avatar = PinAvatarSprite(point: point, appearance: appearance) {
      return register(avatar)
    }
    return switch point.pinStyle {
    case .pointA: "pin-point-a"
    case .pointB: "pin-point-b"
    case .crosshair: "pin-crosshair"
    case .obstruction: "pin-obstruction"
    case .droppedPin: "pin-dropped"
    case .locationFix: locationDotSpriteName(bucket: point.hopIndex ?? 0)
    case .locationFixLatest: "pin-location-latest"
    case .badge: "pin-badge"
    // Node styles always resolve to a mast or an avatar above.
    case .contactChat, .contactRepeater, .contactRoom, .repeater, .repeaterRingBlue, .repeaterRingGreen,
         .repeaterRingWhite, .repeaterHop, .discoveredChat, .discoveredRepeater, .discoveredRoom:
      "pin-badge"
    }
  }

  /// The ground shadow under a repeater's mast (registered, like the mast), or nil for every
  /// other pin, which draws no shadow layer.
  static func groundSpriteName(for point: MapPoint, appearance: MapAvatarAppearance, isSelected: Bool = false) -> String? {
    guard let mast = RepeaterMastSprite(point: point, appearance: appearance, isSelected: isSelected) else { return nil }
    register(mast)
    return mast.groundSpriteName
  }

  /// The flashing red light over a quiet saved repeater's mast, or nil for every other pin.
  static func warningLightSpriteName(for point: MapPoint, appearance: MapAvatarAppearance, isSelected: Bool = false) -> String? {
    RepeaterMastSprite(point: point, appearance: appearance, isSelected: isSelected)?.warningLightSpriteName
  }

  /// Sprites made per pin look (avatars, masts and their ground shadows) rather than once per
  /// style, so the map can drop the ones no pin uses any more.
  static func isPerPinSprite(_ name: String) -> Bool {
    name.hasPrefix(PinAvatarSprite.namePrefix)
      || name.hasPrefix(RepeaterMastSprite.namePrefix)
      || name.hasPrefix(RepeaterMastSprite.groundPrefix)
  }

  // MARK: - Mast sprites

  /// Masts by sprite name, and by their ground shadow's name, so `didFailToLoadImage` and
  /// snapshots can render either from its name. Only a handful of looks exist (beacon, outline,
  /// hop, selection, colour), so this stays small however many repeaters a map shows.
  private static var mastRegistry: [String: RepeaterMastSprite] = [:]

  private static let mastImages: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 200
    return cache
  }()

  /// Remembers a mast under its sprite and ground names and returns the sprite name.
  @discardableResult
  static func register(_ mast: RepeaterMastSprite) -> String {
    let name = mast.spriteName
    if mastRegistry[name] == nil {
      if mastRegistry.count >= avatarRegistryLimit { mastRegistry.removeAll(keepingCapacity: true) }
      mastRegistry[name] = mast
    }
    if mastRegistry[mast.groundSpriteName] == nil {
      mastRegistry[mast.groundSpriteName] = mast
    }
    return name
  }

  /// A registered mast or ground shadow, rendered on first use and then cached.
  static func mastSprite(named name: String) -> UIImage? {
    let isGround = name.hasPrefix(RepeaterMastSprite.groundPrefix)
    guard isGround || name.hasPrefix(RepeaterMastSprite.namePrefix) else { return nil }
    if let cached = mastImages.object(forKey: name as NSString) { return cached }
    guard let mast = mastRegistry[name] else { return nil }
    let image = isGround ? mast.renderGround() : mast.render()
    mastImages.setObject(image, forKey: name as NSString)
    return image
  }

  // MARK: - Avatar sprites

  /// Above this many registered avatars the registry starts over; the map re-registers the pins
  /// it shows on its next update, so only long-gone avatars (and their photo bytes) are dropped.
  private static let avatarRegistryLimit = 1024

  /// Avatar sprites by name, so `didFailToLoadImage` and snapshots can render one from its name.
  private static var avatarRegistry: [String: PinAvatarSprite] = [:]

  /// Rendered avatar sprites. Bounded: a photo pin is a full bitmap, and a busy mesh has many.
  private static let avatarImages: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 300
    return cache
  }()

  /// Remembers an avatar under its sprite name and returns the name.
  @discardableResult
  static func register(_ avatar: PinAvatarSprite) -> String {
    let name = avatar.spriteName
    if avatarRegistry[name] == nil {
      if avatarRegistry.count >= avatarRegistryLimit { avatarRegistry.removeAll(keepingCapacity: true) }
      avatarRegistry[name] = avatar
    }
    return name
  }

  /// A registered avatar's sprite, rendered on first use and then cached.
  static func avatarSprite(named name: String) -> UIImage? {
    guard name.hasPrefix(PinAvatarSprite.namePrefix) else { return nil }
    if let cached = avatarImages.object(forKey: name as NSString) { return cached }
    guard let avatar = avatarRegistry[name] else { return nil }
    let image = avatar.render()
    avatarImages.setObject(image, forKey: name as NSString)
    return image
  }

  // MARK: - Sprite specifications

  private enum RenderStyle {
    case standard
    case crosshair
    case obstruction
  }

  private struct SpriteSpec {
    let name: String
    let circleColor: UIColor
    let iconName: String? // SF Symbol name
    let text: String? // e.g. "A", "B" for point pins
    let renderStyle: RenderStyle
    var centerDot: Bool = false // white dot in the circle head (location hero)
  }

  private static let allSpecs: [SpriteSpec] = [
    // LOS point pins
    SpriteSpec(name: "pin-point-a", circleColor: .systemBlue,
               iconName: nil, text: "A", renderStyle: .standard),
    SpriteSpec(name: "pin-point-b", circleColor: .systemGreen,
               iconName: nil, text: "B", renderStyle: .standard),

    // LOS crosshair target
    SpriteSpec(name: "pin-crosshair", circleColor: .systemPurple,
               iconName: nil, text: "R", renderStyle: .crosshair),

    // LOS obstruction marker
    SpriteSpec(name: "pin-obstruction", circleColor: .systemRed,
               iconName: nil, text: nil, renderStyle: .obstruction),

    // Chat-dropped coordinate pin
    SpriteSpec(name: "pin-dropped", circleColor: .systemPink,
               iconName: "mappin", text: nil, renderStyle: .standard),

    // Node location history hero: the emphasized latest-fix teardrop. The recency
    // dots are rendered separately per bucket in renderAll (theme-specific palette).
    SpriteSpec(name: "pin-location-latest", circleColor: locationHeroColor,
               iconName: nil, text: nil, renderStyle: .standard, centerDot: true),
  ]

  // MARK: - Rendering

  /// A circle-headed teardrop: point pins, the dropped pin and the location hero. Node pins
  /// draw their avatar instead (`PinAvatarSprite`).
  private static func render(_ spec: SpriteSpec) -> UIImage {
    switch spec.renderStyle {
    case .crosshair: return renderCrosshair(spec)
    case .obstruction: return renderObstruction()
    case .standard: break
    }
    let headFill = spec.circleColor
    let glyphColor = UIColor.white

    let circleSize: CGFloat = 36
    let iconSize: CGFloat = 16
    let triangleSize: CGFloat = 10
    let totalWidth = circleSize
    let totalHeight = circleSize + triangleSize - 3

    let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalWidth, height: totalHeight), format: .preferred())
    return renderer.image { ctx in
      let cgContext = ctx.cgContext
      let centerX = totalWidth / 2

      // Circle shadow
      cgContext.saveGState()
      cgContext.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.3).cgColor)
      let circleRect = CGRect(
        x: centerX - circleSize / 2,
        y: 0,
        width: circleSize,
        height: circleSize
      )
      headFill.setFill()
      cgContext.fillEllipse(in: circleRect)
      cgContext.restoreGState()

      // Circle (again without shadow for crisp edge)
      headFill.setFill()
      cgContext.fillEllipse(in: circleRect)

      // Icon or text
      if let iconName = spec.iconName {
        let config = UIImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
        if let icon = UIImage(systemName: iconName, withConfiguration: config)?.withTintColor(glyphColor, renderingMode: .alwaysOriginal) {
          let iconRect = CGRect(
            x: centerX - icon.size.width / 2,
            y: circleRect.midY - icon.size.height / 2,
            width: icon.size.width,
            height: icon.size.height
          )
          icon.draw(in: iconRect)
        }
      } else if let text = spec.text {
        let font = UIFont.systemFont(ofSize: 14, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let textRect = CGRect(
          x: centerX - size.width / 2,
          y: circleRect.midY - size.height / 2,
          width: size.width,
          height: size.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attrs)
      } else if spec.centerDot {
        let dotDiameter: CGFloat = 12
        let dotRect = CGRect(
          x: circleRect.midX - dotDiameter / 2,
          y: circleRect.midY - dotDiameter / 2,
          width: dotDiameter,
          height: dotDiameter
        )
        UIColor.white.setFill()
        cgContext.fillEllipse(in: dotRect)
      }

      // Triangle pointer
      let triangleTop = circleRect.maxY - 3
      let path = UIBezierPath()
      path.move(to: CGPoint(x: centerX - triangleSize / 2, y: triangleTop))
      path.addLine(to: CGPoint(x: centerX + triangleSize / 2, y: triangleTop))
      path.addLine(to: CGPoint(x: centerX, y: triangleTop + triangleSize))
      path.close()
      spec.circleColor.setFill()
      path.fill()
    }
  }

  // MARK: - Pill sprites

  /// Semi-transparent stretchable pill for stats badges.
  /// Registered as a resizable image so MapLibre's `iconTextFit` can stretch
  /// the flat center while preserving the rounded caps.
  private static func renderPillBackground() -> UIImage {
    let cornerRadius: CGFloat = 4
    let size: CGFloat = 2 * cornerRadius + 2
    let shadowPadding: CGFloat = 1
    let totalSize = size + shadowPadding * 2
    let capInset = cornerRadius + shadowPadding

    let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalSize, height: totalSize), format: .preferred())
    let image = renderer.image { ctx in
      let cgContext = ctx.cgContext
      let pillRect = CGRect(x: shadowPadding, y: shadowPadding, width: size, height: size)
      let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: cornerRadius)

      // Shadow pass
      cgContext.saveGState()
      cgContext.setShadow(
        offset: CGSize(width: 0, height: 0.5),
        blur: 1,
        color: UIColor.black.withAlphaComponent(0.15).cgColor
      )
      UIColor.white.setFill()
      pillPath.fill()
      cgContext.restoreGState()

      // Light fill for readability in both light and dark mode
      UIColor.white.withAlphaComponent(0.85).setFill()
      pillPath.fill()
    }

    return image.resizableImage(
      withCapInsets: UIEdgeInsets(top: capInset, left: capInset, bottom: capInset, right: capInset),
      resizingMode: .stretch
    )
  }

  /// Margin around a badge card for its soft shadow.
  static let badgeShadowInset: CGFloat = 3

  /// A pin's name badge: a capsule card (light or dark to suit the basemap) with a hairline
  /// border and soft shadow, a type-tinted dot, the name, and optional secondary info in a
  /// lighter weight. See `MapLabelBadge`.
  static func renderBadgeCard(_ badge: MapLabelBadge) -> UIImage {
    let size = CGFloat(badge.fontSize)
    let titleFont = UIFont.systemFont(ofSize: size, weight: .semibold)
    let detailFont = UIFont.monospacedDigitSystemFont(ofSize: max(size - 1, 10), weight: .regular)
    let titleColor = badge.isDark ? UIColor(white: 1, alpha: 0.95) : UIColor(white: 0, alpha: 0.88)
    let detailColor = badge.isDark ? UIColor(white: 1, alpha: 0.65) : UIColor(white: 0, alpha: 0.55)
    let fill = badge.isDark ? UIColor(white: 0.12, alpha: 0.92) : UIColor(white: 1, alpha: 0.94)
    let border = badge.isDark ? UIColor(white: 1, alpha: 0.16) : UIColor(white: 0, alpha: 0.10)

    let title = NSAttributedString(string: badge.title, attributes: [.font: titleFont, .foregroundColor: titleColor])
    let detail = badge.detail.map {
      NSAttributedString(string: $0, attributes: [.font: detailFont, .foregroundColor: detailColor])
    }
    let titleSize = title.size()
    let detailSize = detail?.size() ?? .zero

    let dotDiameter = (size * 0.6).rounded()
    let dotColor = badge.dotColor
    let horizontalPadding = (size * 0.65).rounded()
    let verticalPadding = (size * 0.3).rounded()
    let gap = (size * 0.4).rounded()

    var contentWidth = titleSize.width
    if dotColor != nil { contentWidth += dotDiameter + gap }
    if detail != nil { contentWidth += gap + detailSize.width }
    let contentHeight = max(titleSize.height, detailSize.height)
    let cardSize = CGSize(
      width: (contentWidth + horizontalPadding * 2).rounded(.up),
      height: (contentHeight + verticalPadding * 2).rounded(.up)
    )
    let inset = badgeShadowInset
    let canvas = CGSize(width: cardSize.width + inset * 2, height: cardSize.height + inset * 2)

    return UIGraphicsImageRenderer(size: canvas, format: .preferred()).image { ctx in
      let cgContext = ctx.cgContext
      let cardRect = CGRect(origin: CGPoint(x: inset, y: inset), size: cardSize)
      let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: cardSize.height / 2)

      cgContext.saveGState()
      cgContext.setShadow(
        offset: CGSize(width: 0, height: 1),
        blur: 2.5,
        color: UIColor.black.withAlphaComponent(badge.isDark ? 0.45 : 0.22).cgColor
      )
      fill.setFill()
      cardPath.fill()
      cgContext.restoreGState()

      border.setStroke()
      let borderPath = UIBezierPath(
        roundedRect: cardRect.insetBy(dx: 0.25, dy: 0.25),
        cornerRadius: cardSize.height / 2 - 0.25
      )
      borderPath.lineWidth = 0.5
      borderPath.stroke()

      var x = cardRect.minX + horizontalPadding
      if let dotColor {
        let dotRect = CGRect(x: x, y: cardRect.midY - dotDiameter / 2, width: dotDiameter, height: dotDiameter)
        dotColor.setFill()
        UIBezierPath(ovalIn: dotRect).fill()
        x += dotDiameter + gap
      }
      title.draw(at: CGPoint(x: x, y: cardRect.midY - titleSize.height / 2))
      x += titleSize.width
      if let detail {
        x += gap
        detail.draw(at: CGPoint(x: x, y: cardRect.midY - detailSize.height / 2))
      }
    }
  }

  /// A small filled dot with a casing stroke and soft shadow: one sampled node
  /// location report, center-anchored on its coordinate. No teardrop pointer, so a
  /// dense trail of them reads as a track of observations rather than a pin field.
  /// `fill` encodes the fix's recency bucket; `casing` carries figure/ground
  /// separation from the basemap and softens on dark ground.
  private static func renderLocationDot(fill: UIColor, casing: UIColor) -> UIImage {
    let diameter = locationDotDiameter
    let strokeWidth: CGFloat = 2
    let padding: CGFloat = 2 // room for the drop shadow
    let total = diameter + strokeWidth + padding * 2

    let renderer = UIGraphicsImageRenderer(size: CGSize(width: total, height: total), format: .preferred())
    return renderer.image { ctx in
      let cgContext = ctx.cgContext
      let dotRect = CGRect(
        x: (total - diameter) / 2,
        y: (total - diameter) / 2,
        width: diameter,
        height: diameter
      )

      cgContext.saveGState()
      cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.3).cgColor)
      fill.setFill()
      cgContext.fillEllipse(in: dotRect)
      cgContext.restoreGState()

      fill.setFill()
      cgContext.fillEllipse(in: dotRect)

      casing.setStroke()
      cgContext.setLineWidth(strokeWidth)
      cgContext.strokeEllipse(in: dotRect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2))
    }
  }

  private static func renderObstruction() -> UIImage {
    let size: CGFloat = 20
    let padding: CGFloat = 3
    let totalSize = size + padding * 2
    let armLength: CGFloat = size / 2 - 1
    let casingWidth: CGFloat = 6
    let strokeWidth: CGFloat = 2.5

    let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalSize, height: totalSize), format: .preferred())
    return renderer.image { ctx in
      let cgContext = ctx.cgContext
      let center = CGPoint(x: totalSize / 2, y: totalSize / 2)

      // Draw white casing (thick white stroke behind the red X)
      cgContext.setStrokeColor(UIColor.white.cgColor)
      cgContext.setLineWidth(casingWidth)
      cgContext.setLineCap(.round)

      cgContext.move(to: CGPoint(x: center.x - armLength, y: center.y - armLength))
      cgContext.addLine(to: CGPoint(x: center.x + armLength, y: center.y + armLength))
      cgContext.move(to: CGPoint(x: center.x + armLength, y: center.y - armLength))
      cgContext.addLine(to: CGPoint(x: center.x - armLength, y: center.y + armLength))
      cgContext.strokePath()

      // Draw red X on top
      cgContext.setStrokeColor(UIColor.systemRed.cgColor)
      cgContext.setLineWidth(strokeWidth)
      cgContext.setLineCap(.round)

      cgContext.move(to: CGPoint(x: center.x - armLength, y: center.y - armLength))
      cgContext.addLine(to: CGPoint(x: center.x + armLength, y: center.y + armLength))
      cgContext.move(to: CGPoint(x: center.x + armLength, y: center.y - armLength))
      cgContext.addLine(to: CGPoint(x: center.x - armLength, y: center.y + armLength))
      cgContext.strokePath()
    }
  }

  private static func renderCrosshair(_ spec: SpriteSpec) -> UIImage {
    let casingWidth: CGFloat = 6
    let capInset = casingWidth / 2
    let size: CGFloat = 44 + capInset * 2
    let gapRadius: CGFloat = 4
    let outerRadius: CGFloat = 22
    let badgeHeight: CGFloat = 20
    let badgeGap: CGFloat = 2
    // Top padding so the crosshair center sits at the image's vertical midpoint
    let topPadding = badgeHeight + badgeGap
    let totalHeight = topPadding + size + badgeGap + badgeHeight

    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: totalHeight), format: .preferred())
    return renderer.image { ctx in
      let cgContext = ctx.cgContext
      let center = CGPoint(x: size / 2, y: topPadding + size / 2)

      // White casing behind crosshair lines
      cgContext.setStrokeColor(UIColor.white.cgColor)
      cgContext.setLineWidth(6)
      cgContext.setLineCap(.round)

      cgContext.move(to: CGPoint(x: center.x, y: center.y - outerRadius))
      cgContext.addLine(to: CGPoint(x: center.x, y: center.y - gapRadius))
      cgContext.move(to: CGPoint(x: center.x, y: center.y + gapRadius))
      cgContext.addLine(to: CGPoint(x: center.x, y: center.y + outerRadius))
      cgContext.move(to: CGPoint(x: center.x - outerRadius, y: center.y))
      cgContext.addLine(to: CGPoint(x: center.x - gapRadius, y: center.y))
      cgContext.move(to: CGPoint(x: center.x + gapRadius, y: center.y))
      cgContext.addLine(to: CGPoint(x: center.x + outerRadius, y: center.y))
      cgContext.strokePath()

      // Crosshair lines
      cgContext.setStrokeColor(UIColor.systemPurple.cgColor)
      cgContext.setLineWidth(2)
      cgContext.setLineCap(.round)

      cgContext.move(to: CGPoint(x: center.x, y: center.y - outerRadius))
      cgContext.addLine(to: CGPoint(x: center.x, y: center.y - gapRadius))
      cgContext.move(to: CGPoint(x: center.x, y: center.y + gapRadius))
      cgContext.addLine(to: CGPoint(x: center.x, y: center.y + outerRadius))
      cgContext.move(to: CGPoint(x: center.x - outerRadius, y: center.y))
      cgContext.addLine(to: CGPoint(x: center.x - gapRadius, y: center.y))
      cgContext.move(to: CGPoint(x: center.x + gapRadius, y: center.y))
      cgContext.addLine(to: CGPoint(x: center.x + outerRadius, y: center.y))
      cgContext.strokePath()

      // "R" badge
      let badgeWidth: CGFloat = 20
      let badgeRect = CGRect(x: center.x - badgeWidth / 2, y: topPadding + size + badgeGap, width: badgeWidth, height: badgeHeight)
      let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: 9)
      UIColor.systemPurple.setFill()
      badgePath.fill()

      let font = UIFont.systemFont(ofSize: 11, weight: .bold)
      let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
      let textSize = ("R" as NSString).size(withAttributes: attrs)
      let textRect = CGRect(
        x: badgeRect.midX - textSize.width / 2,
        y: badgeRect.midY - textSize.height / 2,
        width: textSize.width,
        height: textSize.height
      )
      ("R" as NSString).draw(in: textRect, withAttributes: attrs)
    }
  }
}
