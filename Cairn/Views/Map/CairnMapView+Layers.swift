import MapLibre
import CairnServices
import UIKit

/// Font stack available on the OpenFreeMap glyph server.
/// MapLibre's default ("Open Sans Regular") returns 404, causing silent symbol dropout.
/// Safety: immutable after initialization, only read from @MainActor coordinator methods.
private nonisolated(unsafe) let mapFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])

// MARK: - Layer and source identifiers

enum MapLayerID {
  static let clusterCircles = "cluster-circles"
  static let clusterLabels = "cluster-labels"
  static let unclusteredIcons = "unclustered-icons"
  static let nameLabels = "name-labels"
  static let badgeText = "badge-text"
  static let fixedIcons = "fixed-icons"
  static let fixedNameLabels = "fixed-name-labels"
  static let fixedBadgeText = "fixed-badge-text"
  /// Repeater masts' shadows, flat on the ground under the pins.
  static let mastGrounds = "mast-grounds"
  static let fixedMastGrounds = "fixed-mast-grounds"
  /// Quiet repeaters' flashing red lights, over their masts.
  static let mastLights = "mast-lights"
  static let fixedMastLights = "fixed-mast-lights"
  static let lineLOS = "line-los"
  static let lineLOSCasing = "line-los-casing"
  static let lineTraceUntraced = "line-trace-untraced"
  static let lineTraceWeak = "line-trace-weak"
  static let lineTraceMedium = "line-trace-medium"
  static let lineTraceGood = "line-trace-good"
  static let lineTraceUntracedCasing = "line-trace-untraced-casing"
  static let lineTraceWeakCasing = "line-trace-weak-casing"
  static let lineTraceMediumCasing = "line-trace-medium-casing"
  static let lineTraceGoodCasing = "line-trace-good-casing"
  static let lineMessagePath = "line-message-path"
  static let lineMessagePathCasing = "line-message-path-casing"
  static let lineLocationTrail = "line-location-trail"
  static let lineLocationTrailCasing = "line-location-trail-casing"
  static let lineNavigationTarget = "line-navigation-target"
  static let lineNavigationTargetCasing = "line-navigation-target-casing"
  static let lineNavigationOnTarget = "line-navigation-on-target"
  static let lineNavigationOnTargetCasing = "line-navigation-on-target-casing"
  static let lineTrafficLinkGlow = "line-traffic-link-glow"
  static let lineTrafficLink = "line-traffic-link"
  static let lineTripTrailCasing = "line-trip-trail-casing"
  static let lineTripTrail = "line-trip-trail"
  static let satelliteLayer = "satellite-layer"
  static let topoLayer = "topo-layer"
  static let mutedWash = "muted-wash"
}

enum MapSourceID {
  static let points = "points"
  static let fixedPoints = "fixed-points"
  static let lines = "lines"
  static let satelliteTiles = "satellite-tiles"
  static let topoTiles = "topo-tiles"
}

enum MapPointClustering {
  static func partition(
    _ points: [MapPoint],
    clusteringEnabled: Bool
  ) -> (clusterable: [MapPoint], fixed: [MapPoint]) {
    var clusterable: [MapPoint] = []
    var fixed: [MapPoint] = []
    for point in points {
      if point.isClusterable, clusteringEnabled {
        clusterable.append(point)
      } else {
        fixed.append(point)
      }
    }
    return (clusterable, fixed)
  }
}

extension CairnMapView.Coordinator {
  // MARK: - Update point source data

  /// Point sources and layers use deferred creation: they are created here
  /// on first data arrival, not during style load. This avoids a MapLibre
  /// bug where sources initialized without features ignore later `.shape`
  /// updates.
  func updatePointSource(mapView: MLNMapView) {
    guard let style = mapView.style else { return }

    let partitioned = MapPointClustering.partition(
      currentPoints,
      clusteringEnabled: currentClusteringEnabled
    )
    // In a fixed order (by id): the points arrive in whatever order the store last sorted its nodes,
    // which changes as nodes are heard. Kept as it came, a reload with nothing new would still
    // replace the source and re-place every badge.
    let clusterablePoints = partitioned.clusterable.sorted { $0.id.uuidString < $1.id.uuidString }
    let fixedPoints = partitioned.fixed.sorted { $0.id.uuidString < $1.id.uuidString }
    // Selection and text size are baked into each feature's badge, so a change rebuilds both.
    // Node pins' avatar colours follow the app's appearance, so a change re-renders them too.
    let labelStateChanged = currentSelectedPointID != lastAppliedSelectedPointID
      || currentLabelFontSize != lastAppliedLabelFontSize
      || currentIsDarkMode != lastAppliedLabelIsDark
      || currentAvatarAppearance != lastAppliedAvatarAppearance
    lastAppliedSelectedPointID = currentSelectedPointID
    lastAppliedLabelFontSize = currentLabelFontSize
    lastAppliedLabelIsDark = currentIsDarkMode
    lastAppliedAvatarAppearance = currentAvatarAppearance

    // Clustered (contact) source — rebuild only when the clusterable subset changed,
    // so toggling a fixed pin (the chat-dropped pin) does not re-cluster all contacts.
    var rebuilt = false
    if labelStateChanged || clusterablePoints != lastAppliedClusterablePoints {
      registerSprites(for: clusterablePoints, style: style)
      if let source = clusterSource {
        source.shape = MLNShapeCollectionFeature(
          shapes: clusterablePoints.map { pointFeature(for: $0) }
        )
      } else if !clusterablePoints.isEmpty {
        let features = clusterablePoints.map { pointFeature(for: $0) }
        let source = MLNShapeSource(
          identifier: MapSourceID.points,
          features: features,
          options: [
            .clustered: true,
            .clusterRadius: 44,
            .maximumZoomLevelForClustering: 14,
          ]
        )
        style.addSource(source)
        clusterSource = source
        addClusteredPointLayers(source: source, style: style)
      }
      lastAppliedClusterablePoints = clusterablePoints
      rebuilt = true
    }

    // Fixed source — rebuild only when the fixed subset changed.
    if labelStateChanged || fixedPoints != lastAppliedFixedPoints {
      registerSprites(for: fixedPoints, style: style)
      if let source = fixedSource {
        source.shape = MLNShapeCollectionFeature(
          shapes: fixedPoints.map { pointFeature(for: $0) }
        )
      } else if !fixedPoints.isEmpty {
        let features = fixedPoints.map { pointFeature(for: $0) }
        let source = MLNShapeSource(identifier: MapSourceID.fixedPoints, features: features, options: nil)
        style.addSource(source)
        fixedSource = source
        addFixedPointLayers(source: source, style: style)
      }
      lastAppliedFixedPoints = fixedPoints
      rebuilt = true
    }
    if rebuilt {
      pruneAvatarSprites(in: style)
      updateMastGroundOpacity(style: style)
    }
  }

  /// Drops avatar and mast sprites no pin uses any more (a theme, contrast, name, photo or
  /// selection change gives pins new sprite names), so old ones don't pile up in the image atlas
  /// until the style reloads.
  private func pruneAvatarSprites(in style: MLNStyle) {
    let names = currentPoints.lazy.flatMap { [self.spriteName(for: $0), self.groundSpriteName(for: $0)].compactMap(\.self) }
    let inUse = Set(names.filter { PinSpriteRenderer.isPerPinSprite($0) })
    for name in appliedAvatarSpriteNames.subtracting(inUse) {
      style.removeImage(forName: name)
    }
    appliedAvatarSpriteNames = inUse
  }

  func updateLabelVisibility(mapView: MLNMapView, showLabels: Bool) {
    for layerId in [MapLayerID.nameLabels, MapLayerID.fixedNameLabels] {
      guard let layer = mapView.style?.layer(withIdentifier: layerId) as? MLNSymbolStyleLayer else { continue }
      layer.isVisible = showLabels
    }
  }

  // MARK: - Clustered point layers

  private func addClusteredPointLayers(source: MLNShapeSource, style: MLNStyle) {
    // Cluster circles
    let circleLayer = MLNCircleStyleLayer(identifier: MapLayerID.clusterCircles, source: source)
    circleLayer.predicate = NSPredicate(format: "cluster == YES")
    let radiusStops: [NSNumber: NSNumber] = [0: 18, 50: 24, 100: 30, 200: 38]
    circleLayer.circleRadius = NSExpression(
      forMLNStepping: NSExpression(forKeyPath: "point_count"),
      from: NSExpression(forConstantValue: 18),
      stops: NSExpression(forConstantValue: radiusStops)
    )
    circleLayer.circleColor = NSExpression(forConstantValue: UIColor.systemBlue)
    circleLayer.circleOpacity = NSExpression(forConstantValue: 0.85)
    circleLayer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.8))
    circleLayer.circleStrokeWidth = NSExpression(forConstantValue: 2)
    insertBelowStatsPills(circleLayer, style: style)

    // Cluster count labels
    let clusterLabelLayer = MLNSymbolStyleLayer(identifier: MapLayerID.clusterLabels, source: source)
    clusterLabelLayer.predicate = NSPredicate(format: "cluster == YES")
    clusterLabelLayer.text = NSExpression(format: "CAST(point_count, 'NSString')")
    clusterLabelLayer.textColor = NSExpression(forConstantValue: UIColor.white)
    clusterLabelLayer.textFontSize = NSExpression(forConstantValue: 13)
    clusterLabelLayer.textFontNames = mapFontNames
    clusterLabelLayer.textAllowsOverlap = NSExpression(forConstantValue: true)
    clusterLabelLayer.textIgnoresPlacement = NSExpression(forConstantValue: true)
    insertBelowStatsPills(clusterLabelLayer, style: style)

    // Repeater masts' ground shadows, under everything else this source draws.
    let groundLayer = MLNSymbolStyleLayer(identifier: MapLayerID.mastGrounds, source: source)
    groundLayer.predicate = NSPredicate(format: "cluster != YES AND groundSpriteName != nil")
    configureMastGroundLayer(groundLayer)
    insertBelowPinsAndBadges(groundLayer, style: style)

    // Unclustered pin icons
    let iconLayer = MLNSymbolStyleLayer(identifier: MapLayerID.unclusteredIcons, source: source)
    iconLayer.predicate = NSPredicate(format: "cluster != YES")
    iconLayer.iconImageName = NSExpression(forKeyPath: "spriteName")
    iconLayer.iconOpacity = NSExpression(forKeyPath: "pinOpacity")
    iconLayer.iconAnchor = NSExpression(forConstantValue: "bottom")
    configurePinIconPlacement(iconLayer)
    iconLayer.text = nil
    insertBelowStatsPills(iconLayer, style: style)

    let lightLayer = MLNSymbolStyleLayer(identifier: MapLayerID.mastLights, source: source)
    configureMastLightLayer(lightLayer, extraPredicate: "cluster != YES")
    lightLayer.iconAnchor = NSExpression(forConstantValue: "bottom")
    insertBelowStatsPills(lightLayer, style: style)

    // Stats badge text (trace path midpoints) with pill background
    let badgeLayer = MLNSymbolStyleLayer(identifier: MapLayerID.badgeText, source: source)
    badgeLayer.predicate = NSPredicate(format: "cluster != YES AND badgeText != nil")
    configureBadgeLayer(badgeLayer)
    style.addLayer(badgeLayer)

    // Name badges (under each pin), below every pin layer so pins are placed first.
    let nameLabelLayer = MLNSymbolStyleLayer(identifier: MapLayerID.nameLabels, source: source)
    nameLabelLayer.predicate = NSPredicate(format: "cluster != YES AND labelSpriteName != nil")
    configureNameLabelLayer(nameLabelLayer)
    insertNameLabels(nameLabelLayer, isFixed: false, style: style)
  }

  // MARK: - Fixed point layers

  private func addFixedPointLayers(source: MLNShapeSource, style: MLNStyle) {
    let fixedGroundLayer = MLNSymbolStyleLayer(identifier: MapLayerID.fixedMastGrounds, source: source)
    fixedGroundLayer.predicate = NSPredicate(format: "groundSpriteName != nil")
    configureMastGroundLayer(fixedGroundLayer)
    insertBelowPinsAndBadges(fixedGroundLayer, style: style)

    let fixedIconLayer = MLNSymbolStyleLayer(identifier: MapLayerID.fixedIcons, source: source)
    fixedIconLayer.iconImageName = NSExpression(forKeyPath: "spriteName")
    fixedIconLayer.iconOpacity = NSExpression(forKeyPath: "pinOpacity")
    fixedIconLayer.iconAnchor = NSExpression(forKeyPath: "anchorType")
    configurePinIconPlacement(fixedIconLayer)
    fixedIconLayer.text = nil
    insertBelowStatsPills(fixedIconLayer, style: style)

    let fixedLightLayer = MLNSymbolStyleLayer(identifier: MapLayerID.fixedMastLights, source: source)
    configureMastLightLayer(fixedLightLayer, extraPredicate: nil)
    fixedLightLayer.iconAnchor = NSExpression(forKeyPath: "anchorType")
    insertBelowStatsPills(fixedLightLayer, style: style)

    let fixedBadgeLayer = MLNSymbolStyleLayer(identifier: MapLayerID.fixedBadgeText, source: source)
    fixedBadgeLayer.predicate = NSPredicate(format: "badgeText != nil")
    configureBadgeLayer(fixedBadgeLayer)
    style.addLayer(fixedBadgeLayer)

    let fixedNameLayer = MLNSymbolStyleLayer(identifier: MapLayerID.fixedNameLabels, source: source)
    fixedNameLayer.predicate = NSPredicate(format: "labelSpriteName != nil")
    configureNameLabelLayer(fixedNameLayer)
    insertNameLabels(fixedNameLayer, isFixed: true, style: style)
  }

  /// Puts a source's name badges below every pin, with the fixed source's badges always above
  /// the clustered source's, whichever source was made first. MapLibre places the higher layer's
  /// badges first, so between the two layers that order, not `MapLabelBadge.sortKey`, decides who
  /// wins. The fixed pins are the ones whose names must stay: this radio, a dropped pin, the
  /// tools' anchors and the repeaters passing traffic. Without this, a map that drew this radio
  /// before its nodes had loaded hid the radio's name under any node's name that touched it.
  private func insertNameLabels(_ layer: MLNStyleLayer, isFixed: Bool, style: MLNStyle) {
    let otherID = isFixed ? MapLayerID.nameLabels : MapLayerID.fixedNameLabels
    guard let other = style.layer(withIdentifier: otherID) else {
      insertBelowPointSymbols(layer, style: style)
      return
    }
    if isFixed {
      style.insertLayer(layer, above: other)
    } else {
      style.insertLayer(layer, below: other)
    }
  }

  // MARK: - Placement order

  /// Our pin and stats layers. Symbol placement runs from the top layer down, so keeping every
  /// name badge beneath all of these means pins and stats claim their space first and a badge
  /// that would cover any pin gives way, whichever source (clustered or fixed) was added last.
  private static let pointSymbolLayerIDs: Set<String> = [
    MapLayerID.clusterCircles, MapLayerID.clusterLabels, MapLayerID.unclusteredIcons,
    MapLayerID.badgeText, MapLayerID.fixedIcons, MapLayerID.fixedBadgeText,
  ]

  /// Inserts `layer` just below the lowest of our pin/stats layers (and so above the lines and
  /// every basemap layer, whose labels then make way for it), or on top when none exist yet.
  private func insertBelowPointSymbols(_ layer: MLNStyleLayer, style: MLNStyle) {
    if let lowest = style.layers.first(where: { Self.pointSymbolLayerIDs.contains($0.identifier) }) {
      style.insertLayer(layer, below: lowest)
    } else {
      style.addLayer(layer)
    }
  }

  /// Every pin, name badge and shadow layer of ours. Shadows go below all of them, so a shadow
  /// never draws over a name badge or another source's pin.
  private static let pinAndBadgeLayerIDs: Set<String> = pointSymbolLayerIDs.union([
    MapLayerID.nameLabels, MapLayerID.fixedNameLabels, MapLayerID.mastGrounds, MapLayerID.fixedMastGrounds,
  ])

  /// Inserts `layer` just below the lowest of our pin, badge and shadow layers (so above the
  /// lines and the basemap), or on top when none exist yet.
  private func insertBelowPinsAndBadges(_ layer: MLNStyleLayer, style: MLNStyle) {
    if let lowest = style.layers.first(where: { Self.pinAndBadgeLayerIDs.contains($0.identifier) }) {
      style.insertLayer(layer, below: lowest)
    } else {
      style.addLayer(layer)
    }
  }

  /// Stats pill layers, which must sit above every pin layer so they're placed before the pins.
  private static let statsPillLayerIDs: Set<String> = [MapLayerID.badgeText, MapLayerID.fixedBadgeText]

  /// Inserts a pin layer just below the lowest stats pill layer, or on top when none exist yet.
  /// The point sources are created lazily (e.g. clustering turned on after a scan already filled
  /// the fixed source), so without this a later source's pins would land above the other source's
  /// pills, be placed first, and hide any pill that touches a pin.
  private func insertBelowStatsPills(_ layer: MLNStyleLayer, style: MLNStyle) {
    if let lowest = style.layers.first(where: { Self.statsPillLayerIDs.contains($0.identifier) }) {
      style.insertLayer(layer, below: lowest)
    } else {
      style.addLayer(layer)
    }
  }

  /// Pins always draw (overlap allowed) but still claim their space, so name badges and the
  /// basemap's own labels are placed around them instead of over them.
  private func configurePinIconPlacement(_ layer: MLNSymbolStyleLayer) {
    layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
    layer.iconIgnoresPlacement = NSExpression(forConstantValue: false)
    layer.iconScale = NSExpression(forKeyPath: "pinScale")   // repeaters smaller (`pinScale(for:)`)
    // Pins face the viewer at any tilt, so a repeater's mast stands upright from its ground point
    // (MapLibre's default for point symbols, stated because the mast's look depends on it).
    layer.iconPitchAlignment = NSExpression(forConstantValue: "viewport")
    layer.iconRotationAlignment = NSExpression(forConstantValue: "viewport")
  }

  /// A mast's shadow lies on the map: flat, foreshortened as the map tilts and turning with it, so
  /// it always falls the same way across the ground. It never claims space or hides, and every
  /// repeater shares one sprite (`RepeaterMastSprite.groundSpriteName`).
  private func configureMastGroundLayer(_ layer: MLNSymbolStyleLayer) {
    layer.iconImageName = NSExpression(forKeyPath: "groundSpriteName")
    layer.iconAnchor = NSExpression(forConstantValue: "center")
    layer.iconPitchAlignment = NSExpression(forConstantValue: "map")
    layer.iconRotationAlignment = NSExpression(forConstantValue: "map")
    layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
    layer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
    layer.iconOpacity = mastGroundOpacity()
  }

  /// Shadows fade with their pin (a quiet Traffic repeater's goes with it) and soften on a light
  /// basemap, where black reads heavier; a dark map or imagery takes them at full strength.
  private func mastGroundOpacity() -> NSExpression {
    let strength = currentIsDarkMode || currentMapStyle == .satellite ? 1.0 : 0.8
    return NSExpression(format: "pinOpacity * %@", NSNumber(value: strength))
  }

  /// A quiet saved repeater's red light, flashed by `MastLightFlasher`: drawn over the mast it
  /// sits on (a sprite the mast's size, anchored as it is), never claiming space.
  private func configureMastLightLayer(_ layer: MLNSymbolStyleLayer, extraPredicate: String?) {
    let lit = "lightSpriteName != nil"
    layer.predicate = NSPredicate(format: [extraPredicate, lit].compactMap(\.self).joined(separator: " AND "))
    layer.iconImageName = NSExpression(forKeyPath: "lightSpriteName")
    layer.iconPitchAlignment = NSExpression(forConstantValue: "viewport")
    layer.iconRotationAlignment = NSExpression(forConstantValue: "viewport")
    layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
    layer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
    layer.iconOpacity = mastLightFlasher.opacity
  }

  /// Applies the flash's current step to both light layers.
  func updateMastLightOpacity(style: MLNStyle) {
    for id in [MapLayerID.mastLights, MapLayerID.fixedMastLights] {
      guard let layer = style.layer(withIdentifier: id) as? MLNSymbolStyleLayer else { continue }
      layer.iconOpacity = mastLightFlasher.opacity
    }
  }

  /// Re-applies the shadows' strength after the basemap changed (theme, or satellite on or off).
  func updateMastGroundOpacity(style: MLNStyle) {
    for id in [MapLayerID.mastGrounds, MapLayerID.fixedMastGrounds] {
      guard let layer = style.layer(withIdentifier: id) as? MLNSymbolStyleLayer else { continue }
      layer.iconOpacity = mastGroundOpacity()
    }
  }

  // MARK: - Line layers

  func setupLineLayers(style: MLNStyle) {
    guard style.source(withIdentifier: MapSourceID.lines) == nil else { return }
    let source = MLNShapeSource(identifier: MapSourceID.lines, features: [], options: nil)
    style.addSource(source)

    let losCasing = MLNLineStyleLayer(identifier: MapLayerID.lineLOSCasing, source: source)
    losCasing.predicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.los.rawValue)
    losCasing.lineColor = NSExpression(forConstantValue: UIColor.white)
    losCasing.lineOpacity = NSExpression(forConstantValue: 0.8)
    losCasing.lineWidth = NSExpression(forConstantValue: 6)
    losCasing.lineDashPattern = NSExpression(forConstantValue: [0.7, 1.3])
    losCasing.lineJoin = NSExpression(forConstantValue: "round")
    losCasing.lineCap = NSExpression(forConstantValue: "round")
    style.addLayer(losCasing)

    let losLayer = MLNLineStyleLayer(identifier: MapLayerID.lineLOS, source: source)
    losLayer.predicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.los.rawValue)
    losLayer.lineColor = NSExpression(forConstantValue: UIColor.systemBlue)
    losLayer.lineWidth = NSExpression(forConstantValue: 3)
    losLayer.lineDashPattern = NSExpression(forConstantValue: [1.4, 2.6])
    losLayer.lineJoin = NSExpression(forConstantValue: "round")
    losLayer.lineCap = NSExpression(forConstantValue: "round")
    losLayer.lineOpacity = NSExpression(forKeyPath: "segmentOpacity")
    style.addLayer(losLayer)

    let white = NSExpression(forConstantValue: UIColor.white)
    let casingOpacity = NSExpression(forConstantValue: 0.8)
    let roundJoin = NSExpression(forConstantValue: "round")
    let roundCap = NSExpression(forConstantValue: "round")

    let untracedCasing = MLNLineStyleLayer(identifier: MapLayerID.lineTraceUntracedCasing, source: source)
    untracedCasing.predicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.traceUntraced.rawValue)
    untracedCasing.lineColor = white
    untracedCasing.lineOpacity = casingOpacity
    untracedCasing.lineWidth = NSExpression(forConstantValue: 5)
    untracedCasing.lineDashPattern = NSExpression(forConstantValue: [0.7, 1.3])
    untracedCasing.lineJoin = roundJoin
    untracedCasing.lineCap = roundCap
    style.addLayer(untracedCasing)

    let untracedLayer = MLNLineStyleLayer(identifier: MapLayerID.lineTraceUntraced, source: source)
    untracedLayer.predicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.traceUntraced.rawValue)
    untracedLayer.lineColor = NSExpression(forConstantValue: UIColor.systemGray)
    untracedLayer.lineWidth = NSExpression(forConstantValue: 2)
    untracedLayer.lineDashPattern = NSExpression(forConstantValue: [1.75, 3.25])
    untracedLayer.lineJoin = roundJoin
    untracedLayer.lineCap = roundCap
    style.addLayer(untracedLayer)

    let weakCasing = MLNLineStyleLayer(identifier: MapLayerID.lineTraceWeakCasing, source: source)
    weakCasing.predicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.traceWeak.rawValue)
    weakCasing.lineColor = white
    weakCasing.lineOpacity = casingOpacity
    weakCasing.lineWidth = NSExpression(forConstantValue: 6)
    weakCasing.lineDashPattern = NSExpression(forConstantValue: [0.7, 1.3])
    weakCasing.lineJoin = roundJoin
    weakCasing.lineCap = roundCap
    style.addLayer(weakCasing)

    let weakLayer = MLNLineStyleLayer(identifier: MapLayerID.lineTraceWeak, source: source)
    weakLayer.predicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.traceWeak.rawValue)
    weakLayer.lineColor = NSExpression(forConstantValue: SNRQuality.poor.uiColor)
    weakLayer.lineWidth = NSExpression(forConstantValue: 3)
    weakLayer.lineDashPattern = NSExpression(forConstantValue: [1.4, 2.6])
    weakLayer.lineJoin = roundJoin
    weakLayer.lineCap = roundCap
    style.addLayer(weakLayer)

    let mediumCasing = MLNLineStyleLayer(identifier: MapLayerID.lineTraceMediumCasing, source: source)
    mediumCasing.predicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.traceMedium.rawValue)
    mediumCasing.lineColor = white
    mediumCasing.lineOpacity = casingOpacity
    mediumCasing.lineWidth = NSExpression(forConstantValue: 6)
    mediumCasing.lineDashPattern = NSExpression(forConstantValue: [0.7, 1.3])
    mediumCasing.lineJoin = roundJoin
    mediumCasing.lineCap = roundCap
    style.addLayer(mediumCasing)

    let mediumLayer = MLNLineStyleLayer(identifier: MapLayerID.lineTraceMedium, source: source)
    mediumLayer.predicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.traceMedium.rawValue)
    mediumLayer.lineColor = NSExpression(forConstantValue: SNRQuality.fair.uiColor)
    mediumLayer.lineWidth = NSExpression(forConstantValue: 3)
    mediumLayer.lineDashPattern = NSExpression(forConstantValue: [1.4, 2.6])
    mediumLayer.lineJoin = roundJoin
    mediumLayer.lineCap = roundCap
    style.addLayer(mediumLayer)

    // Good: width 4, solid → casing width 7
    let goodCasing = MLNLineStyleLayer(identifier: MapLayerID.lineTraceGoodCasing, source: source)
    goodCasing.predicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.traceGood.rawValue)
    goodCasing.lineColor = white
    goodCasing.lineOpacity = casingOpacity
    goodCasing.lineWidth = NSExpression(forConstantValue: 7)
    goodCasing.lineJoin = roundJoin
    goodCasing.lineCap = roundCap
    style.addLayer(goodCasing)

    let goodLayer = MLNLineStyleLayer(identifier: MapLayerID.lineTraceGood, source: source)
    goodLayer.predicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.traceGood.rawValue)
    goodLayer.lineColor = NSExpression(forConstantValue: SNRQuality.good.uiColor)
    goodLayer.lineWidth = NSExpression(forConstantValue: 4)
    style.addLayer(goodLayer)

    // Message path: solid blue with a white casing (no dashes) — a direct
    // node-to-node route, visually distinct from the dashed LOS line.
    let messagePathCasing = MLNLineStyleLayer(identifier: MapLayerID.lineMessagePathCasing, source: source)
    messagePathCasing.predicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.messagePath.rawValue)
    messagePathCasing.lineColor = white
    messagePathCasing.lineOpacity = casingOpacity
    messagePathCasing.lineWidth = NSExpression(forConstantValue: 6)
    messagePathCasing.lineJoin = roundJoin
    messagePathCasing.lineCap = roundCap
    style.addLayer(messagePathCasing)

    let messagePathLayer = MLNLineStyleLayer(identifier: MapLayerID.lineMessagePath, source: source)
    messagePathLayer.predicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.messagePath.rawValue)
    messagePathLayer.lineColor = NSExpression(forConstantValue: UIColor.systemBlue)
    messagePathLayer.lineWidth = NSExpression(forConstantValue: 3)
    messagePathLayer.lineJoin = roundJoin
    messagePathLayer.lineCap = roundCap
    style.addLayer(messagePathLayer)

    // Location trail: a faint dashed connector threading location reports in time
    // order, neutral and de-emphasized, since it is not a proven route. A long
    // silence is left unbridged by the builder, so no segment spans a real gap.
    let locationTrailCasing = MLNLineStyleLayer(identifier: MapLayerID.lineLocationTrailCasing, source: source)
    locationTrailCasing.predicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.locationTrail.rawValue)
    locationTrailCasing.lineColor = white
    locationTrailCasing.lineOpacity = casingOpacity
    locationTrailCasing.lineWidth = NSExpression(forConstantValue: 5)
    locationTrailCasing.lineDashPattern = NSExpression(forConstantValue: [0.8, 1.4])
    locationTrailCasing.lineJoin = roundJoin
    locationTrailCasing.lineCap = roundCap
    style.addLayer(locationTrailCasing)

    let locationTrailLayer = MLNLineStyleLayer(identifier: MapLayerID.lineLocationTrail, source: source)
    locationTrailLayer.predicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.locationTrail.rawValue)
    locationTrailLayer.lineColor = NSExpression(forConstantValue: UIColor.systemGray)
    locationTrailLayer.lineWidth = NSExpression(forConstantValue: 2.5)
    locationTrailLayer.lineDashPattern = NSExpression(forConstantValue: [1.6, 2.8])
    locationTrailLayer.lineJoin = roundJoin
    locationTrailLayer.lineCap = roundCap
    style.addLayer(locationTrailLayer)

    // Navigation guide: a dashed accent line from the user to the GPS map's target, cased
    // like the others so it reads on every basemap.
    let navigationPredicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.navigationTarget.rawValue)
    let navigationCasing = MLNLineStyleLayer(identifier: MapLayerID.lineNavigationTargetCasing, source: source)
    navigationCasing.predicate = navigationPredicate
    navigationCasing.lineColor = white
    navigationCasing.lineOpacity = casingOpacity
    navigationCasing.lineWidth = NSExpression(forConstantValue: 6)
    navigationCasing.lineDashPattern = NSExpression(forConstantValue: [0.7, 1.3])
    navigationCasing.lineJoin = roundJoin
    navigationCasing.lineCap = roundCap
    style.addLayer(navigationCasing)

    let navigationLayer = MLNLineStyleLayer(identifier: MapLayerID.lineNavigationTarget, source: source)
    navigationLayer.predicate = navigationPredicate
    navigationLayer.lineColor = NSExpression(forConstantValue: UIColor.systemBlue)
    navigationLayer.lineWidth = NSExpression(forConstantValue: 3)
    navigationLayer.lineDashPattern = NSExpression(forConstantValue: [1.4, 2.6])
    navigationLayer.lineJoin = roundJoin
    navigationLayer.lineCap = roundCap
    style.addLayer(navigationLayer)

    // The guide while the phone faces the target: solid, wider and green, as the readout turns.
    let onTargetPredicate = NSPredicate(
      format: "lineStyle == %@", MapLine.LineStyle.navigationTargetOnTarget.rawValue
    )
    let onTargetCasing = MLNLineStyleLayer(identifier: MapLayerID.lineNavigationOnTargetCasing, source: source)
    onTargetCasing.predicate = onTargetPredicate
    onTargetCasing.lineColor = white
    onTargetCasing.lineOpacity = casingOpacity
    onTargetCasing.lineWidth = NSExpression(forConstantValue: 7)
    onTargetCasing.lineJoin = roundJoin
    onTargetCasing.lineCap = roundCap
    style.addLayer(onTargetCasing)

    let onTargetLayer = MLNLineStyleLayer(identifier: MapLayerID.lineNavigationOnTarget, source: source)
    onTargetLayer.predicate = onTargetPredicate
    onTargetLayer.lineColor = NSExpression(forConstantValue: UIColor.systemGreen)
    onTargetLayer.lineWidth = NSExpression(forConstantValue: 4)
    onTargetLayer.lineJoin = roundJoin
    onTargetLayer.lineCap = roundCap
    style.addLayer(onTargetLayer)

    // Traffic links: a wide blurred glow under a thin core, both in Cairn's teal, so links the
    // mesh has used lately read as lit channels between repeaters. Each link's strength rides in
    // its opacity; the Traffic map's lasers run along them.
    let trafficPredicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.trafficLink.rawValue)
    let trafficTeal = UIColor(red: 0.08, green: 0.71, blue: 0.65, alpha: 1)
    let trafficGlow = MLNLineStyleLayer(identifier: MapLayerID.lineTrafficLinkGlow, source: source)
    trafficGlow.predicate = trafficPredicate
    trafficGlow.lineColor = NSExpression(forConstantValue: trafficTeal)
    trafficGlow.lineOpacity = NSExpression(format: "segmentOpacity * 0.45")
    trafficGlow.lineWidth = NSExpression(forConstantValue: 10)
    trafficGlow.lineBlur = NSExpression(forConstantValue: 6)
    trafficGlow.lineJoin = roundJoin
    trafficGlow.lineCap = roundCap
    style.addLayer(trafficGlow)

    let trafficLayer = MLNLineStyleLayer(identifier: MapLayerID.lineTrafficLink, source: source)
    trafficLayer.predicate = trafficPredicate
    trafficLayer.lineColor = NSExpression(forConstantValue: trafficTeal)
    trafficLayer.lineOpacity = NSExpression(forKeyPath: "segmentOpacity")
    trafficLayer.lineWidth = NSExpression(forConstantValue: 2)
    trafficLayer.lineJoin = roundJoin
    trafficLayer.lineCap = roundCap
    style.addLayer(trafficLayer)

    // A day's trail (the Trips page): a dark casing, then the line coloured by where each segment sits
    // in the day's elevation range: Cairn's teal at the lowest, the sunrise gold midway, the sunset
    // orange at the highest (the colours the sun line uses), so the climbs read at a glance.
    let tripPredicate = NSPredicate(format: "lineStyle == %@", MapLine.LineStyle.tripTrail.rawValue)
    let tripCasing = MLNLineStyleLayer(identifier: MapLayerID.lineTripTrailCasing, source: source)
    tripCasing.predicate = tripPredicate
    tripCasing.lineColor = NSExpression(forConstantValue: UIColor(white: 0.08, alpha: 1))
    tripCasing.lineOpacity = NSExpression(forConstantValue: 0.55)
    tripCasing.lineWidth = NSExpression(forConstantValue: 7)
    tripCasing.lineJoin = roundJoin
    tripCasing.lineCap = roundCap
    style.addLayer(tripCasing)

    let tripLayer = MLNLineStyleLayer(identifier: MapLayerID.lineTripTrail, source: source)
    tripLayer.predicate = tripPredicate
    let stops: [NSNumber: UIColor] = [
      0: UIColor(red: 0.08, green: 0.71, blue: 0.65, alpha: 1),
      0.5: UIColor(red: 0.95, green: 0.76, blue: 0.31, alpha: 1),
      1: UIColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 1),
    ]
    tripLayer.lineColor = NSExpression(
      forMLNInterpolating: NSExpression(forKeyPath: "elevationFraction"),
      curveType: .linear,
      parameters: nil,
      stops: NSExpression(forConstantValue: stops)
    )
    tripLayer.lineWidth = NSExpression(forConstantValue: 4)
    tripLayer.lineJoin = roundJoin
    tripLayer.lineCap = roundCap
    style.addLayer(tripLayer)
  }

  func updateLineSource(mapView: MLNMapView) {
    guard let source = mapView.style?.source(withIdentifier: MapSourceID.lines) as? MLNShapeSource else { return }

    let features = currentLines.map { line -> MLNPolylineFeature in
      var coords = line.coordinates
      let feature = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
      var attributes: [String: Any] = [
        "lineStyle": line.style.rawValue,
        "segmentOpacity": line.opacity,
        "lineId": line.id,
      ]
      if let fraction = line.elevationFraction { attributes["elevationFraction"] = fraction }
      feature.attributes = attributes
      return feature
    }
    source.shape = MLNShapeCollectionFeature(shapes: features)
  }

  // MARK: - Raster tile sources

  func setupRasterSources(style: MLNStyle, mapView: MLNMapView) {
    guard style.source(withIdentifier: MapSourceID.satelliteTiles) == nil else {
      updateRasterLayerVisibility(mapView: mapView)
      return
    }
    let satSource = MLNRasterTileSource(
      identifier: MapSourceID.satelliteTiles,
      tileURLTemplates: [MapTileURLs.esriWorldImagery],
      options: [
        .tileSize: 256,
        .maximumZoomLevel: 19,
        .attributionHTMLString: "<a href=\"https://www.esri.com\">Esri</a>",
      ]
    )
    style.addSource(satSource)
    let satLayer = MLNRasterStyleLayer(identifier: MapLayerID.satelliteLayer, source: satSource)
    satLayer.isVisible = false
    style.addLayer(satLayer)

    let topoSource = MLNRasterTileSource(
      identifier: MapSourceID.topoTiles,
      tileURLTemplates: [MapTileURLs.openTopoMapA, MapTileURLs.openTopoMapB, MapTileURLs.openTopoMapC],
      options: [
        .tileSize: 256,
        .maximumZoomLevel: 17,
        .attributionHTMLString: "<a href=\"https://opentopomap.org\">OpenTopoMap</a>",
      ]
    )
    style.addSource(topoSource)
    let topoLayer = MLNRasterStyleLayer(identifier: MapLayerID.topoLayer, source: topoSource)
    topoLayer.isVisible = false
    style.addLayer(topoLayer)

    updateRasterLayerVisibility(mapView: mapView)
  }

  func updateRasterLayerVisibility(mapView: MLNMapView) {
    guard let style = mapView.style else { return }
    style.layer(withIdentifier: MapLayerID.satelliteLayer)?.isVisible = currentMapStyle == .satellite
    style.layer(withIdentifier: MapLayerID.topoLayer)?.isVisible = currentMapStyle == .topo
    updateMastGroundOpacity(style: style)
  }

  // MARK: - Shared layer configuration

  /// Below this zoom (a whole region in view) badges are hidden: pins alone read better there.
  static let nameBadgeMinimumZoom: Float = 7

  /// Name badges hang just under the pin's tip, so they never cover the pin glyph, and take
  /// part in collision: a badge that would overlap a pin, a stats badge, or a higher-priority
  /// badge (`MapLabelBadge.sortKey`) is hidden while its pin stays.
  func configureNameLabelLayer(_ layer: MLNSymbolStyleLayer) {
    layer.iconImageName = NSExpression(forKeyPath: "labelSpriteName")
    layer.iconOpacity = NSExpression(forKeyPath: "pinOpacity")
    layer.iconAnchor = NSExpression(forConstantValue: "top")
    layer.iconOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 8)))
    layer.symbolSortKey = NSExpression(forKeyPath: "labelSortKey")
    layer.iconAllowsOverlap = NSExpression(forConstantValue: false)
    layer.iconIgnoresPlacement = NSExpression(forConstantValue: false)
    layer.iconPadding = NSExpression(forConstantValue: 1)
    layer.minimumZoomLevel = Self.nameBadgeMinimumZoom
    layer.isVisible = currentShowLabels
  }

  private func configureBadgeLayer(_ layer: MLNSymbolStyleLayer) {
    layer.text = NSExpression(forKeyPath: "badgeText")
    layer.textFontSize = NSExpression(forConstantValue: 11)
    layer.textFontNames = mapFontNames
    layer.textColor = NSExpression(forConstantValue: UIColor.black)
    // Stats are placed before name badges (layer order), so name badges make way for them. Two
    // stats pills that would overlap don't both draw: the higher priority one (the selected
    // trace's, then the stronger link, `MapLabelBadge.statsSortKey`) stays and the other hides
    // until zooming in separates them. Text and pill hide together.
    layer.symbolSortKey = NSExpression(forKeyPath: "badgeSortKey")
    layer.textAllowsOverlap = NSExpression(forConstantValue: false)
    layer.textIgnoresPlacement = NSExpression(forConstantValue: false)
    layer.iconAllowsOverlap = NSExpression(forConstantValue: false)
    layer.iconIgnoresPlacement = NSExpression(forConstantValue: false)
    layer.textOptional = NSExpression(forConstantValue: false)
    layer.iconOptional = NSExpression(forConstantValue: false)
    layer.textPadding = NSExpression(forConstantValue: 2)
    // A dimmed trace's stats fade with its line.
    layer.textOpacity = NSExpression(forKeyPath: "pinOpacity")
    layer.iconOpacity = NSExpression(forKeyPath: "pinOpacity")
    layer.iconImageName = NSExpression(forConstantValue: "pill-bg")
    layer.iconTextFit = NSExpression(forConstantValue: NSValue(mlnIconTextFit: .both))
    layer.iconTextFitPadding = NSExpression(forConstantValue: NSValue(uiEdgeInsets: UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)))
  }

  // MARK: - Private helpers

  /// Register pin and name-label sprites before replacing the source so the
  /// first layout already has images and `didFailToLoadImage` does not fire.
  private func registerSprites(for points: [MapPoint], style: MLNStyle) {
    for point in points {
      _ = PinSpriteRenderer.renderOnDemand(name: spriteName(for: point), into: style)
      if let ground = groundSpriteName(for: point) {
        _ = PinSpriteRenderer.renderOnDemand(name: ground, into: style)
      }
      if let badge = labelBadge(for: point) {
        _ = PinSpriteRenderer.renderOnDemand(name: badge.spriteName, into: style)
      }
    }
  }

  private func labelBadge(for point: MapPoint) -> MapLabelBadge? {
    MapLabelBadge(
      point: point,
      isDark: currentIsDarkMode,
      fontSize: currentLabelFontSize,
      dotColor: PinAvatarSprite(point: point, appearance: currentAvatarAppearance)?.colors().fill
    )
  }

  private func pointFeature(for point: MapPoint) -> MLNPointFeature {
    let feature = MLNPointFeature()
    feature.coordinate = point.coordinate
    feature.identifier = point.id.uuidString
    var attributes: [String: Any] = [
      "pointId": point.id.uuidString,
      "spriteName": spriteName(for: point),
      "anchorType": iconAnchor(for: point),
      "pinOpacity": point.opacity,
      "pinScale": pinScale(for: point),
    ]
    if let ground = groundSpriteName(for: point) { attributes["groundSpriteName"] = ground }
    if let light = PinSpriteRenderer.warningLightSpriteName(
      for: point,
      appearance: currentAvatarAppearance,
      isSelected: point.id == currentSelectedPointID
    ) {
      attributes["lightSpriteName"] = light
    }
    if let badge = labelBadge(for: point) {
      attributes["labelSpriteName"] = badge.spriteName
      attributes["labelSortKey"] = MapLabelBadge.sortKey(
        pinStyle: point.pinStyle,
        isFavorite: point.isFavorite,
        hopIndex: point.hopIndex,
        opacity: point.opacity,
        isSelected: point.id == currentSelectedPointID,
        isThisRadio: point.avatar?.isRadio == true,
        tieBreak: MapLabelBadge.tieBreak(for: point.id)
      )
    }
    if let hopIndex = point.hopIndex { attributes["hopIndex"] = hopIndex }
    if let badgeText = point.badgeText {
      attributes["badgeText"] = badgeText
      attributes["badgeSortKey"] = MapLabelBadge.statsSortKey(opacity: point.opacity, snr: point.badgeSNR)
    }
    feature.attributes = attributes
    return feature
  }

  /// Repeaters stand thick on the ground where a mesh is busy, and at a node pin's full size they
  /// covered one another and the map. They draw smaller; the selected one is full size, so its
  /// callout sits where it always has. The path tools' hop and ring pins keep their size.
  static let repeaterPinScale: Double = 0.68

  private func pinScale(for point: MapPoint) -> Double {
    guard point.id != currentSelectedPointID else { return 1 }
    switch point.pinStyle {
    case .contactRepeater, .repeater, .discoveredRepeater: return Self.repeaterPinScale
    default: return 1
    }
  }

  private func iconAnchor(for point: MapPoint) -> String {
    switch point.pinStyle {
    case .crosshair, .obstruction, .locationFix: "center"
    default: "bottom"
    }
  }

  /// A repeater's mast, a node pin's avatar or the base sprite for its style
  /// (`PinSpriteRenderer.spriteName`). The selected repeater's mast draws larger.
  private func spriteName(for point: MapPoint) -> String {
    PinSpriteRenderer.spriteName(
      for: point,
      appearance: currentAvatarAppearance,
      isSelected: point.id == currentSelectedPointID
    )
  }

  /// A repeater mast's ground shadow, or nil for every other pin.
  private func groundSpriteName(for point: MapPoint) -> String? {
    PinSpriteRenderer.groundSpriteName(
      for: point,
      appearance: currentAvatarAppearance,
      isSelected: point.id == currentSelectedPointID
    )
  }
}
